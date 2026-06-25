# frozen_string_literal: true

require 'spec_helper'

# Verifies the gem's own file/constant layout conforms to Zeitwerk's naming
# conventions, so it could be managed by Zeitwerk (and, more practically, so a
# host Rails app eager-loading in production never trips over our structure).
#
# The gem itself loads via plain `require_relative` (see lib/http_connection_pool.rb)
# and takes NO runtime dependency on Zeitwerk — this check exists purely as a
# guard against a future file/constant naming mistake.
#
# Why a subprocess? spec_helper already `require`d the gem, so its constants are
# defined and its files are in $LOADED_FEATURES. A Zeitwerk loader in this same
# process would see those as already-loaded and the eager_load would be a no-op,
# proving nothing. Running in a clean Ruby process exercises a real autoload.
RSpec.describe 'Zeitwerk compliance', :integration do
  # The standard "Zeitwerk for gems" setup: manage lib/, but ignore the entry
  # file, version.rb, and errors.rb. version.rb defines VERSION, not Version
  # (the one universal exception every gem makes); errors.rb defines the whole
  # error hierarchy (Error, ConfigurationError, TimeoutError, ...) directly under
  # HttpConnectionPool rather than a single Errors constant matching its filename,
  # so it is ignored for the same reason.
  let(:probe) do
    <<~RUBY
      require 'zeitwerk'
      lib = File.join(#{gem_root.inspect}, 'lib')
      loader = Zeitwerk::Loader.new
      loader.push_dir(lib)
      loader.ignore(File.join(lib, 'http_connection_pool.rb'))
      loader.ignore(File.join(lib, 'http_connection_pool', 'version.rb'))
      loader.ignore(File.join(lib, 'http_connection_pool', 'errors.rb'))
      loader.setup
      loader.eager_load
      # Force-resolve every constant Zeitwerk is responsible for; a naming
      # mismatch raises NameError here.
      %w[
        HttpConnectionPool::Pool
        HttpConnectionPool::Registry
        HttpConnectionPool::Connectable
        HttpConnectionPool::Connectable::ClassMethods
        HttpConnectionPool::Connectable::PoolAccessors
        HttpConnectionPool::Pool::TimeoutError
        HttpConnectionPool::Pool::ClosedError
      ].each { |const| Object.const_get(const) }
      print 'ZEITWERK_OK'
    RUBY
  end

  let(:gem_root) { File.expand_path('../..', __dir__) }

  it 'eager-loads cleanly under a real Zeitwerk loader in a clean process' do
    output = run_in_clean_process(probe)
    expect(output).to include('ZEITWERK_OK')
  end

  it 'reports no setup issues from Zeitwerk' do
    # Zeitwerk.with_loader-style check: a misnamed file would raise during
    # setup/eager_load and the marker would be absent, with the error on stderr.
    output = run_in_clean_process(probe)
    expect(output).not_to match(/Zeitwerk::|NameError|expected file/)
  end

  # Runs a Ruby snippet in a fresh process under the project bundle, returning
  # combined stdout+stderr.
  def run_in_clean_process(source)
    require 'open3'
    out, status = Open3.capture2e('bundle', 'exec', 'ruby', '-e', source, chdir: gem_root)
    raise "probe process failed (#{status.exitstatus}):\n#{out}" unless status.success?

    out
  end
end
