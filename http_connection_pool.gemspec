# frozen_string_literal: true

require_relative 'lib/http_connection_pool/version'

Gem::Specification.new do |spec|
  spec.name    = 'http_connection_pool'
  spec.version = HttpConnectionPool::VERSION
  spec.authors = ['bbarberBPL']

  spec.summary     = 'Thread-safe persistent HTTP connection pool for the http.rb gem'
  spec.description = 'Provides a singleton connection pool per URL origin using http.rb (httprb), ' \
                     'with a Connectable mixin for easy integration into service/API client classes.'
  spec.license     = 'MIT'

  spec.required_ruby_version = '>= 3.3.0'

  # MRI (CRuby) only. http.rb requires `llhttp`, which publishes only a native
  # C-extension build (no JRuby/TruffleRuby variant), so this gem cannot run on
  # non-MRI engines — the extension fails to build there at install time. The
  # limitation is documented in the README rather than enforced with a platform
  # guard, since the native-build failure is already a hard stop.

  spec.files = Dir['lib/**/*.rb', 'LICENSE', 'README.md']

  # >= 1.3.7: fixes CVE-2026-54904 (AtomicReference#update livelock, high severity),
  # CVE-2026-54905 (ReentrantReadWriteLock read-count overflow), and
  # CVE-2026-54906 (ReadWriteLock wrong-thread write release).
  # Verified: 1.3.7 published 2026-06-16 on RubyGems; advisories confirmed via
  # api.github.com/advisories (GHSA-h8w8-99g7-qmvj, GHSA-wv3x-4vxv-whpp, GHSA-6wx8-w4f5-wwcr).
  spec.add_dependency 'concurrent-ruby', '>= 1.3.7', '~> 1.3'
  spec.add_dependency 'connection_pool', '>= 2.5.5', '< 3'
  # `~> 6.0` intentionally allows 6.0.4+ to be picked up automatically once
  # published — 6.0.4 fixes a credential-leak via protocol-relative paths
  # against a persistent origin (GHSA-r98x-p6m8-xcrv). The floor is NOT pinned
  # to 6.0.4 because that version is not yet on RubyGems; pinning it would make
  # this gem uninstallable. Bump to '>= 6.0.4', '< 7' once 6.0.4 ships.
  spec.add_dependency 'http', '~> 6.0'
end
