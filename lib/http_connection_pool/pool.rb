# frozen_string_literal: true

# Require only the concurrent-ruby primitives we use rather than the whole
# library — this keeps load time and memory footprint down (the same approach
# Rails takes).
require 'concurrent/atomic/atomic_boolean'
require 'connection_pool'
require 'http'
require_relative 'errors'

module HttpConnectionPool
  # Manages a pool of persistent HTTP::Session connections for a single URL
  # origin. On http v6, HTTP.persistent returns an HTTP::Session, and http's own
  # README notes that a persistent session is not thread-safe on its own — it
  # points to the `connection_pool` gem for thread-safe persistent use. That is
  # exactly the pattern this class follows: each caller checks out its own
  # Session for the duration of a request.
  #
  # Backed by the `connection_pool` gem (>= 2.5.5), which is both thread- and
  # Fiber.scheduler-aware: when running under a fiber scheduler, blocking
  # checkouts yield to the scheduler instead of parking the OS thread.
  #
  # Pool instances are never created directly — obtain them through Registry.
  class Pool
    # Backward-compatible aliases — the canonical classes live in errors.rb
    # under HttpConnectionPool. Existing `rescue Pool::TimeoutError` keeps working.
    TimeoutError = HttpConnectionPool::TimeoutError
    ClosedError  = HttpConnectionPool::ClosedError

    DEFAULT_SIZE    = 5
    DEFAULT_TIMEOUT = 5.0 # seconds to wait for a connection to become available

    # @param origin  [String] canonical origin, e.g. "https://api.example.com:443"
    # @param size    [Integer] maximum number of concurrent connections
    # @param timeout [Float]   seconds to block waiting for a free connection
    # @param options [Hash]    options forwarded to every HTTP::Session (headers, timeout, ssl, etc.)
    def initialize(origin:, size: DEFAULT_SIZE, timeout: DEFAULT_TIMEOUT, **options)
      @origin  = origin
      @size    = Integer(size)
      @timeout = Float(timeout)
      @options = deep_freeze(options)

      raise ArgumentError, 'size must be >= 1' unless @size >= 1
      raise ArgumentError, 'timeout must be > 0' unless @timeout.positive?

      @closed = Concurrent::AtomicBoolean.new(false)
      @pool   = ::ConnectionPool.new(size: @size, timeout: @timeout) { build_connection }
    end

    attr_reader :origin, :size

    # Yields a live HTTP::Session scoped to @origin, returning it to the pool when done.
    #
    # @raise [ClosedError]  if the pool has been shut down
    # @raise [TimeoutError] if no connection is available within the configured timeout
    # @yieldparam conn [HTTP::Session]
    # @return [Object] the value returned by the block
    def with(&)
      raise ClosedError, "pool for #{@origin} is closed" if @closed.true?

      @pool.with(&)
    rescue ::ConnectionPool::TimeoutError => e
      raise TimeoutError, "no connection available for #{@origin} within #{@timeout}s (#{e.message})"
    rescue ::ConnectionPool::PoolShuttingDownError
      # Another thread closed the pool between our @closed check and checkout.
      # Surface it as our own ClosedError rather than leaking the backing
      # library's exception type.
      raise ClosedError, "pool for #{@origin} is closed"
    end

    # Immediately close every connection and mark the pool as closed.
    # Any subsequent call to #with will raise ClosedError.
    def close
      return unless @closed.make_true

      @pool.shutdown do |conn|
        conn&.close
      rescue StandardError
        # Closing a stale connection should not mask the shutdown.
        nil
      end
    end

    def closed?
      @closed.true?
    end

    def stats
      available = @pool.available
      {
        origin: @origin,
        size: @size,
        checked_out: @size - available,
        idle: available,
        closed: closed?
      }
    end

    # Redacted inspect. The default Ruby #inspect would dump @options verbatim,
    # exposing any Authorization header / auth token / SSL material in logs,
    # backtraces, and error-reporting payloads. We list only the option *keys*
    # (never their values) plus the non-sensitive pool state.
    def inspect
      keys = @options.keys
      option_keys = keys.empty? ? 'none' : keys.join(', ')
      "#<#{self.class.name} origin=#{@origin.inspect} size=#{@size} " \
        "timeout=#{@timeout} closed=#{closed?} options=[#{option_keys}]>"
    end
    alias to_s inspect

    # Belt-and-suspenders for pretty-printers (pp / awesome_print), which call
    # #pretty_print rather than #inspect and would otherwise reach @options.
    def pretty_print(pp)
      pp.text(inspect)
    end

    private

    # Freeze the options hash and every nested hash/array/value, so a pool's
    # configuration cannot mutate after creation (and cannot diverge from the
    # options that were hashed into its registry key).
    def deep_freeze(obj)
      case obj
      when Hash  then obj.each { |k, v| [k, v].each { |e| deep_freeze(e) } }
      when Array then obj.each { |v| deep_freeze(v) }
      end
      obj.freeze
    end

    def build_connection
      session = HTTP::Session.new(HTTP::Options.new(**native_options))
      apply_chainable(session)
    end

    # Directly-mappable HTTP::Options fields, including persistent (= origin).
    # auth is folded into headers as an Authorization header, matching what
    # http.rb's own `auth` chainable does internally.
    def native_options
      opts = { persistent: @origin, headers: headers_with_auth }
      opts[:ssl] = @options[:ssl] if @options[:ssl]
      # TODO: case C — when ssl_context becomes safely keyable, set
      # opts[:ssl_context] = @options[:ssl_context] here. It is currently
      # rejected at the registry keying boundary, so it never reaches this
      # method. See docs/superpowers/specs/2026-06-25-error-handling-design.md.
      opts
    end

    # Merge auth into the headers hash as an Authorization header. Uses merge
    # (not mutation) so the frozen @options[:headers] is never modified.
    def headers_with_auth
      headers = @options[:headers] || {}
      return headers unless @options[:auth]

      headers.merge('Authorization' => @options[:auth])
    end

    # timeout/proxy need http.rb's own translation (number/hash -> timeout_class
    # + timeout_options; positional args -> proxy_hash), so they stay chainable.
    # Early-return when neither is set (the common case) to avoid extra
    # HTTP::Session allocations from branch/dup.
    def apply_chainable(session)
      return session unless @options[:timeout] || @options[:proxy]

      session = session.timeout(@options[:timeout]) if @options[:timeout]
      session = session.via(*@options[:proxy])      if @options[:proxy]
      session
    end
  end
end
