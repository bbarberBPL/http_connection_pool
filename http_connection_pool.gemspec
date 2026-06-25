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

  # Tested on MRI (CRuby). http.rb itself selects its parser by engine —
  # `llhttp` (native C extension) on MRI and `llhttp-ffi` on JRuby (see the
  # platform conditional at the bottom of http's gemspec) — so JRuby support is
  # plausible and planned, but installing and running this gem under JRuby is
  # untested for now. No platform guard is set, so JRuby installs are not
  # blocked; they are simply not yet verified.

  spec.files = Dir['lib/**/*.rb', 'LICENSE', 'README.md']

  # >= 1.3.7: fixes CVE-2026-54904 (AtomicReference#update livelock, high severity),
  # CVE-2026-54905 (ReentrantReadWriteLock read-count overflow), and
  # CVE-2026-54906 (ReadWriteLock wrong-thread write release).
  # Verified: 1.3.7 published 2026-06-16 on RubyGems; advisories confirmed via
  # api.github.com/advisories (GHSA-h8w8-99g7-qmvj, GHSA-wv3x-4vxv-whpp, GHSA-6wx8-w4f5-wwcr).
  spec.add_dependency 'concurrent-ruby', '>= 1.3.7', '~> 1.3'
  spec.add_dependency 'connection_pool', '>= 2.5.5', '< 3'
  spec.add_dependency 'http', '~> 6.0'
end
