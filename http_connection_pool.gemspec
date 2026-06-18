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

  spec.files = Dir['lib/**/*.rb', 'LICENSE', 'README.md']

  spec.add_dependency 'concurrent-ruby', '~> 1.3'
  spec.add_dependency 'connection_pool', '>= 2.5.5', '< 3'
  spec.add_dependency 'http', '~> 6.0'
end
