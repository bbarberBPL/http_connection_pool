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
      @options = options.freeze

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

    def build_connection
      apply_options(persistent_session)
    end

    # http v6 removed the `.ssl` chainable, and SSL config must be present in a
    # session's options before `.persistent` is called. So we seed a Session
    # with any SSL material first, then turn it persistent; for the common
    # no-SSL case we use HTTP.persistent directly.
    def persistent_session
      ssl = ssl_options
      return HTTP.persistent(@origin) if ssl.empty?

      HTTP::Session.new(**ssl).persistent(@origin)
    end

    def ssl_options
      if @options[:ssl_context]
        { ssl_context: @options[:ssl_context] }
      elsif @options[:ssl]
        { ssl: @options[:ssl] }
      else
        {}
      end
    end

    def apply_options(session)
      session = session.timeout(@options[:timeout]) if @options[:timeout]
      session = session.headers(@options[:headers]) if @options[:headers]
      session = session.auth(@options[:auth])       if @options[:auth]
      session = session.via(*@options[:proxy])      if @options[:proxy]
      session
    end
  end
end
