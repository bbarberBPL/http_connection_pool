# frozen_string_literal: true

require_relative 'registry'

module HttpConnectionPool
  # Mixin that gives any class a `connection_pool` class-level accessor and a
  # `with_connection` method for safely borrowing a persistent HTTP client.
  #
  # ── Include (instance + class API) ──────────────────────────────────────────
  #
  #   class GithubClient
  #     include HttpConnectionPool::Connectable
  #
  #     self.base_url     = 'https://api.github.com'
  #     self.pool_size    = 10
  #     self.pool_timeout = 3.0
  #     self.pool_options = { headers: { 'Authorization' => "Bearer #{ENV['GITHUB_TOKEN']}" } }
  #
  #     def user(login)
  #       with_connection { |conn| conn.get("/users/#{login}").parse }
  #     end
  #   end
  #
  # ── Subclassing ─────────────────────────────────────────────────────────────
  #
  # Subclasses inherit base_url, pool_size, pool_timeout, and pool_options from
  # their parent. Each class that declares its own pool_options receives its own
  # isolated pool (keyed by origin + options digest), so a subclass that adds
  # credentials never shares connections with the base class or siblings:
  #
  #   class AdminClient < GithubClient
  #     self.pool_options = { headers: { 'Authorization' => "Bearer #{ENV['ADMIN_TOKEN']}" } }
  #   end
  #
  # ── Extend (class-level methods only) ───────────────────────────────────────
  #
  #   module GithubAPI
  #     extend HttpConnectionPool::Connectable
  #
  #     self.base_url = 'https://api.github.com'
  #
  #     def self.user(login)
  #       with_connection { |conn| conn.get("/users/#{login}").parse }
  #     end
  #   end
  #
  module Connectable
    # Called when the module is included into a class.
    def self.included(base)
      base.extend(ClassMethods)
      base.extend(PoolAccessors)
    end

    # Called when the module is extended onto an object/module.
    def self.extended(base)
      base.extend(ClassMethods)
      base.extend(PoolAccessors)
    end

    # Class-level configuration attributes.
    # Readers walk the ancestor chain so subclasses inherit configuration
    # without having to restate it; the writer pins the value on that class.
    module PoolAccessors
      attr_writer :base_url, :pool_size, :pool_timeout, :pool_options

      def base_url
        # Walk superclass chain until we find a set value.
        klass = self
        while klass
          return klass.instance_variable_get(:@base_url) if
            klass.instance_variable_defined?(:@base_url) && klass.instance_variable_get(:@base_url)

          klass = klass.respond_to?(:superclass) ? klass.superclass : nil
        end

        raise NotImplementedError,
              "#{name || inspect} must set `self.base_url = <url>` before using the connection pool"
      end

      def pool_size
        klass = self
        while klass
          return klass.instance_variable_get(:@pool_size) if
            klass.instance_variable_defined?(:@pool_size)

          klass = klass.respond_to?(:superclass) ? klass.superclass : nil
        end
        Pool::DEFAULT_SIZE
      end

      def pool_timeout
        klass = self
        while klass
          return klass.instance_variable_get(:@pool_timeout) if
            klass.instance_variable_defined?(:@pool_timeout)

          klass = klass.respond_to?(:superclass) ? klass.superclass : nil
        end
        Pool::DEFAULT_TIMEOUT
      end

      def pool_options
        klass = self
        while klass
          return klass.instance_variable_get(:@pool_options) if
            klass.instance_variable_defined?(:@pool_options)

          klass = klass.respond_to?(:superclass) ? klass.superclass : nil
        end
        {}
      end
    end

    # Class-level behaviour available after include/extend.
    module ClassMethods
      # Borrow a connection from the pool and yield it to the block.
      #
      # @yieldparam conn [HTTP::Client] a persistent client pre-configured for base_url
      # @return [Object] the return value of the block
      def with_connection(&)
        connection_pool.with(&)
      end

      # Lazy accessor for the pool — initialised on first call and memoized so
      # the request hot path avoids re-parsing the URL and re-allocating the
      # options hash on every `with_connection`. The memo is dropped whenever
      # the underlying pool has been closed (e.g. via the registry), so the
      # next call transparently obtains a fresh pool.
      #
      # @return [HttpConnectionPool::Pool]
      def connection_pool
        cached = @connection_pool
        return cached if cached && !cached.closed?

        @connection_pool = HttpConnectionPool::Registry.instance.pool_for(
          base_url,
          size: pool_size,
          timeout: pool_timeout,
          **pool_options
        )
      end

      # Explicitly release and close this class's pool.
      # The next call to `with_connection` will open a fresh pool.
      def release_connection_pool
        @connection_pool = nil
        HttpConnectionPool::Registry.instance.release(base_url, **pool_options)
      end

      # Snapshot of the pool's current stats.
      #
      # @return [Hash]
      def connection_pool_stats
        connection_pool.stats
      end
    end

    # ── Instance-level proxy methods (only meaningful after `include`) ────────

    # @see ClassMethods#with_connection
    def with_connection(&)
      self.class.with_connection(&)
    end

    # @see ClassMethods#connection_pool
    def connection_pool
      self.class.connection_pool
    end

    # @see ClassMethods#connection_pool_stats
    def connection_pool_stats
      self.class.connection_pool_stats
    end
  end
end
