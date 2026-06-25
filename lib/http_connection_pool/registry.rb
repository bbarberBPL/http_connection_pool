# frozen_string_literal: true

# Require only the concurrent-ruby primitives we use rather than the whole
# library — keeps load time and footprint down.
require 'concurrent/atomic/atomic_reference'
require 'concurrent/map'
require 'digest'
require 'uri'
require_relative 'errors'
require_relative 'pool'

module HttpConnectionPool
  # Global, thread-safe registry that holds one Pool per (origin, options) pair.
  #
  # Pools are keyed by a SHA-256 digest of the canonical origin + options, so
  # two callers targeting the same host with different credentials each get their
  # own isolated pool — no credential confusion, no error. This makes subclassing
  # safe: a subclass that overrides pool_options gets a distinct pool from its
  # parent even when both share the same base_url.
  #
  # The registry itself is a singleton (one instance per process). It is not
  # implemented with the `Singleton` module so it can be replaced in tests.
  # Storage is backed by `Concurrent::Map`, and the singleton slot by
  # `Concurrent::AtomicReference`, so reads are lock-free under contention.
  #
  # Usage:
  #   registry = HttpConnectionPool::Registry.instance
  #   registry.pool_for('https://api.example.com').with { |conn| conn.get('/status') }
  class Registry
    # Backward-compatible alias — canonical class lives in errors.rb.
    PoolLimitError = HttpConnectionPool::PoolLimitError

    SUPPORTED_SCHEMES = %w[http https].freeze

    @instance_ref = Concurrent::AtomicReference.new(nil)

    # @return [Registry] the process-wide singleton instance
    def self.instance
      existing = @instance_ref.get
      return existing if existing

      candidate = new(max_pools: @configured_max_pools)
      @instance_ref.compare_and_set(nil, candidate) ? candidate : @instance_ref.get
    end

    # Configure the process-wide singleton's pool ceiling. Must be called before
    # the singleton is first used (e.g. in a Rails initializer); raises if the
    # singleton already exists, since max_pools is fixed at construction.
    #
    # @param max_pools [Integer, nil]
    def self.configure(max_pools:)
      raise 'Registry singleton already initialised; call configure earlier' if @instance_ref.get

      @configured_max_pools = max_pools
    end

    # Replace the singleton — primarily for testing.
    def self.reset!
      previous = @instance_ref.get_and_set(nil)
      @configured_max_pools = nil
      previous&.close_all
    end

    # @param max_pools [Integer, nil]
    #   Optional ceiling on the number of distinct origins held at once. nil
    #   (the default) means unlimited. Set this when origins can be influenced
    #   by untrusted input (webhook targets, redirect hosts, user-supplied
    #   URLs) to bound memory and file-descriptor use — without it, each new
    #   origin retains a pool and its sockets indefinitely.
    def initialize(max_pools: nil)
      @pools     = Concurrent::Map.new
      @max_pools = max_pools && Integer(max_pools)

      raise ArgumentError, 'max_pools must be >= 1' if @max_pools && @max_pools < 1
    end

    attr_reader :max_pools

    # Return (or lazily create) a Pool for the given URL's origin + options.
    #
    # Each unique (origin, options) combination gets its own isolated pool, so
    # two callers sharing a host but using different credentials (Authorization
    # headers, auth tokens, etc.) never share connections.
    #
    # @param url     [String]  any URL whose scheme+host+port will be used as the key
    # @param size    [Integer] pool size (ignored if an identical pool already exists)
    # @param timeout [Float]   checkout timeout in seconds (ignored if pool already exists)
    # @param options [Hash]    HTTP client options forwarded to Pool (headers, auth, ssl, etc.)
    # @return [Pool]
    def pool_for(url, size: Pool::DEFAULT_SIZE, timeout: Pool::DEFAULT_TIMEOUT, **options)
      origin = extract_origin(url)
      key    = pool_key(origin, options)

      loop do
        existing = @pools[key]
        return existing if existing && !existing.closed?

        # Only new keys count against the cap; reusing/replacing an existing
        # key is always allowed.
        ensure_within_limit!(key)

        candidate = Pool.new(origin: origin, size: size, timeout: timeout, **options)
        resolved  = insert_or_resolve(key, candidate)
        return resolved if resolved
      end
    end

    # Remove and close the pool that exactly matches the given URL + options.
    # Without options it closes the no-options pool for the origin.
    #
    # @param url     [String]
    # @param options [Hash]
    def release(url, **options)
      key  = pool_key(extract_origin(url), options)
      pool = @pools.delete(key)
      pool&.close
    end

    # Close every pool and clear the registry.
    def close_all
      @pools.each_pair do |key, pool|
        @pools.delete_pair(key, pool)
        pool.close
      end
    end

    # Evict every pool that has already been closed out-of-band (e.g. via
    # Pool#close rather than Registry#release). Dead pools are otherwise only
    # reclaimed when their exact key is requested again, so a long-running
    # process that closes pools directly should call this periodically to free
    # the retained Pool objects (and their option material) and the cap slots
    # they would otherwise hold. Returns the number of pools swept.
    def sweep_closed!
      swept = 0
      @pools.each_pair do |key, pool|
        swept += 1 if pool.closed? && @pools.delete_pair(key, pool)
      end
      swept
    end

    # @return [Array<Hash>] snapshot of stats for every registered pool
    def stats
      result = []
      @pools.each_pair { |_key, pool| result << pool.stats }
      result
    end

    # Safe inspect — shows pool count and cap without dumping internal keys or
    # any pool state that might reference credential material.
    def inspect
      limit = @max_pools ? @max_pools.to_s : 'unlimited'
      "#<#{self.class.name} pools=#{@pools.size} max_pools=#{limit}>"
    end
    alias to_s inspect

    private

    # Derive a stable, collision-resistant registry key from the canonical
    # origin and options. The key is a SHA-256 hex digest of the origin and a
    # deeply-sorted, canonical representation of the options hash, so:
    #   * key ordering within nested hashes does not matter — callers that
    #     supply the same headers in different insertion order get the same pool
    #   * mixed symbol/string keys are handled safely (sorted by to_s)
    #   * the digest itself never appears in user-visible output, so it cannot
    #     be used to verify guesses about credential values
    def pool_key(origin, options)
      Digest::SHA256.hexdigest("#{origin}|#{normalize_options(options).inspect}")
    end

    # Recursively sort hash keys (by their string representation) so that two
    # logically identical option hashes always produce the same digest regardless
    # of key-insertion order.  Arrays and scalar values are passed through as-is.
    def normalize_options(obj)
      case obj
      when Hash
        obj.each_with_object({}) { |(k, v), h| h[k] = normalize_options(v) }
           .sort_by { |k, _| k.to_s }.to_h
      when Array then obj.map { |v| normalize_options(v) }
      else obj
      end
    end

    # Atomically insert `candidate`, or resolve what is already there.
    # Returns the Pool to hand back, or nil to signal the caller should retry
    # the loop (a stale closed pool was evicted).
    def insert_or_resolve(key, candidate)
      # compute_if_absent only inserts when no live entry exists.
      winner = @pools.compute_if_absent(key) { candidate }
      return candidate if winner.equal?(candidate)

      # A stale closed pool is occupying the slot — evict it and retry.
      if winner.closed?
        @pools.delete_pair(key, winner)
        candidate.close
        return nil
      end

      # Lost the race to another caller with identical options; reuse theirs.
      candidate.close
      winner
    end

    # Enforce the optional max_pools ceiling before creating a new pool.
    # This is a soft cap: the size check and the insert are not a single
    # atomic step (doing so would require a global lock and defeat the
    # lock-free Concurrent::Map). Under heavy concurrency the count may briefly
    # overshoot by roughly the number of distinct keys racing to be created,
    # but growth stays bounded — which is the point of the DoS backstop.
    #
    # Only *live* pools count toward the cap: a pool closed out-of-band (via
    # Pool#close) is dead weight, not an active connection set, so it must not
    # block creation of a new pool. It will be evicted lazily when its key is
    # re-requested, or eagerly via sweep_closed!.
    def ensure_within_limit!(key)
      return unless @max_pools
      return if @pools.key?(key) || live_pool_count < @max_pools

      raise PoolLimitError,
            "connection pool limit of #{@max_pools} reached. " \
            'Release unused pools or raise max_pools.'
    end

    def live_pool_count
      count = 0
      @pools.each_value { |pool| count += 1 unless pool.closed? }
      count
    end

    # Normalise a full URL down to its origin (scheme + host + port).
    #
    # @param url [String]
    # @return [String]  e.g. "https://api.example.com:443"
    def extract_origin(url)
      uri = URI.parse(url)
      raise ArgumentError, "URL must have a scheme (http/https): #{url}" unless uri.scheme
      raise ArgumentError, "unsupported scheme: #{uri.scheme}"           unless SUPPORTED_SCHEMES.include?(uri.scheme)
      raise ArgumentError, "URL must have a host: #{url}"                unless uri.host

      # URI always populates the default port (80/443) for http/https, so
      # uri.port is reliable here and no fallback table is needed.
      "#{uri.scheme}://#{uri.host}:#{uri.port}"
    end
  end
end
