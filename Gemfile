# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

group :development, :test do
  gem 'bundler-audit',        '~> 0.9', require: false
  gem 'irb',                  '~> 1.14'
  gem 'rake',                 '~> 13.0'
  gem 'rspec',                '~> 3.13'
  gem 'rubocop',              '~> 1.65', require: false
  gem 'rubocop-performance',             require: false
  gem 'rubocop-rake',                    require: false
  gem 'rubocop-rspec',                   require: false
end

# Rails compatibility is verified at test time only — Rails is deliberately
# NOT a runtime dependency (see the gemspec), so the gem stays usable outside
# Rails. We pin activesupport to the Rails 7.2.x series because that is the
# version most consuming apps run today; bumping this line is how we'd test a
# newer Rails. activesupport drags in concurrent-ruby under Rails' own
# constraint (~> 1.0, >= 1.3.1), which is what proves our `~> 1.3` requirement
# coexists with Rails. Note: activesupport alone does not pull in
# connection_pool (that lives in activerecord/activejob); that overlap is
# asserted directly in spec/integration/rails_compatibility_spec.rb.
group :test do
  gem 'activesupport', '~> 7.2.3'

  # Zeitwerk is verified at test time only. The gem loads itself with plain
  # require_relative (so it is invisible to a host Rails app's loader and never
  # needs Zeitwerk at runtime); this dependency exists purely so
  # spec/integration/zeitwerk_compliance_spec.rb can assert the gem's own
  # file/constant layout would pass a Zeitwerk eager-load.
  gem 'zeitwerk', '~> 2.6'
end
