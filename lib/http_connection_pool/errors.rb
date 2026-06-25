# frozen_string_literal: true

module HttpConnectionPool
  # Root of every error raised by this gem's pool/registry layer. Rescue this to
  # catch any failure that originates here. Request-body errors from http.rb
  # (HTTP::Error and subclasses) are NOT remapped — they propagate raw, since a
  # request made inside a `with`/`with_connection` block is the caller's own.
  class Error < StandardError; end

  # Unusable configuration, detected before any I/O (URL validation, option
  # keyability). All ConfigurationError subclasses are raised at setup time.
  class ConfigurationError < Error; end

  # A URL had no scheme, an unsupported scheme, or no host.
  class InvalidURLError < ConfigurationError; end

  # An option value cannot be safely/canonically used as part of a pool key
  # (e.g. an SSLContext object, whose inspect omits distinguishing material and
  # would silently collide). See README "Error handling".
  class OptionKeyError < ConfigurationError; end

  # Creating a new pool would exceed the registry's max_pools cap.
  class PoolLimitError < Error; end

  # No connection became available within the checkout timeout.
  class TimeoutError < Error; end

  # A pool was used after it was closed.
  class ClosedError < Error; end
end
