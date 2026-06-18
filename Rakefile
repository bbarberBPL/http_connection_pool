# frozen_string_literal: true

require 'rspec/core/rake_task'
require 'rubocop/rake_task'
require 'bundler/audit/task'

RSpec::Core::RakeTask.new(:spec)
RuboCop::RakeTask.new(:rubocop)

# Provides `bundle:audit:check` (scan against the advisory DB) and
# `bundle:audit:update` (refresh the DB from the network).
Bundler::Audit::Task.new

# The default task must run offline, so it only *checks* against whatever
# advisory DB is present rather than forcing a network update (which would make
# `rake` fail without connectivity). CI should run `rake audit` to refresh the
# DB first; `bundle:audit:check` no-ops gracefully if the DB was never cloned.
desc 'Refresh the advisory DB, then scan dependencies for known CVEs'
task audit: ['bundle:audit:update', 'bundle:audit:check']

desc 'Audit dependencies (offline), run RuboCop, then the RSpec suite'
task ci: ['bundle:audit:check', :rubocop, :spec]

task default: :ci
