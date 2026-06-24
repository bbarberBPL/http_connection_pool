# frozen_string_literal: true

require 'rspec/core/rake_task'
require 'rubocop/rake_task'
require 'bundler/audit/task'
require 'bundler/gem_tasks'

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

# `bundler/gem_tasks` provides `build` (into pkg/). We extend it to record
# SHA-256 and SHA-512 digests of the built .gem so a published artifact can be
# verified against the repo. The .gem itself stays gitignored; only the
# checksum files (under checksums/) are committed. Publishing remains a manual,
# user-only step — there is deliberately no automated push task here.
namespace :build do
  desc 'Build the gem, then write SHA-256 and SHA-512 checksums to checksums/'
  task :checksum do
    require 'digest'
    require_relative 'lib/http_connection_pool/version'

    gem_path = File.join('pkg', "http_connection_pool-#{HttpConnectionPool::VERSION}.gem")
    Rake::Task['build'].invoke unless File.exist?(gem_path)

    write_checksum(gem_path, Digest::SHA256, 'sha256')
    write_checksum(gem_path, Digest::SHA512, 'sha512')

    # bundler/gem_tasks' build writes its own raw-format `<name>.gem.sha512`
    # (digest only, no filename). Remove it so checksums/ holds exactly one
    # sha256 and one sha512, both in the standard `<digest>  <file>` format
    # that `sha256sum -c` / `sha512sum -c` can verify.
    redundant = File.join('checksums', "#{File.basename(gem_path)}.sha512")
    rm_f redundant
  end
end

def write_checksum(gem_path, digest_class, extension)
  mkdir_p 'checksums'
  digest = digest_class.file(gem_path).hexdigest
  basename = File.basename(gem_path, '.gem')
  out = File.join('checksums', "#{basename}.#{extension}")
  File.write(out, "#{digest}  #{File.basename(gem_path)}\n")
  puts "#{extension}: #{digest}  -> #{out}"
end
