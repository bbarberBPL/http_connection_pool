# frozen_string_literal: true

require 'spec_helper'

# Verifies the gem coexists with Rails without taking Rails as a runtime
# dependency. We load activesupport (the foundational Rails component, and the
# one that shares concurrent-ruby with us) and exercise the gem under it.
#
# What this proves:
#   * Bundler can resolve our deps alongside Rails' — if our constraints
#     clashed with Rails', `bundle install` for the test group would already
#     have failed. The version-overlap examples below assert the resolved
#     versions satisfy BOTH sides explicitly.
#   * The Connectable mixin behaves correctly inside an activesupport-managed
#     process (the typical Rails service-object pattern).
#
# What this intentionally does NOT cover (would require Combustion / a dummy
# app): Zeitwerk autoloading, initializer ordering, and a booted web stack.
require 'active_support'
require 'active_support/version'

RSpec.describe 'Rails compatibility', :integration do
  before { allow(fake_client).to receive(:get).and_return(:ok) }

  it 'loads against the Rails 7.2 series' do
    expect(ActiveSupport::VERSION::STRING).to start_with('7.2')
  end

  describe 'shared dependency version overlap' do
    # These are the gems Rails and this gem both depend on. If a future bump
    # to either side breaks the overlap, these examples fail loudly with the
    # offending version rather than surfacing as a mysterious runtime error in
    # a consuming app.

    it 'resolves a concurrent-ruby that satisfies both Rails and this gem' do
      version = Gem.loaded_specs.fetch('concurrent-ruby').version

      # Rails 7.2: "~> 1.0", ">= 1.3.1"; this gem: "~> 1.3".
      expect(Gem::Requirement.new('~> 1.0', '>= 1.3.1')).to be_satisfied_by(version)
      expect(Gem::Requirement.new('~> 1.3')).to be_satisfied_by(version)
    end

    it 'resolves a connection_pool that satisfies both Rails and this gem' do
      version = Gem.loaded_specs.fetch('connection_pool').version

      # Rails (activerecord/activejob): ">= 2.2.5"; this gem: ">= 2.5.5", "< 3".
      expect(Gem::Requirement.new('>= 2.2.5')).to be_satisfied_by(version)
      expect(Gem::Requirement.new('>= 2.5.5', '< 3')).to be_satisfied_by(version)
    end
  end

  describe 'the Connectable mixin inside a Rails-style service object' do
    let(:service_class) do
      Class.new do
        include HttpConnectionPool::Connectable

        self.base_url     = 'https://api.internal.example.com'
        self.pool_size    = 4
        self.pool_timeout = 2.0

        def fetch_status
          with_connection { |conn| conn.get('/status') }
        end
      end
    end

    it 'borrows a pooled connection from an instance' do
      result = service_class.new.fetch_status
      expect(result).to eq(:ok)
      # The pool keys on the normalised origin (scheme + host + port).
      expect(HTTP).to have_received(:persistent).with('https://api.internal.example.com:443')
    end

    it 'shares a single pool across instances, as a Rails singleton service would' do
      a = service_class.new
      b = service_class.new
      expect(a.connection_pool).to be(b.connection_pool)
    end

    it 'survives an ActiveSupport class reload (constant redefinition)' do
      # Rails' development reloader discards and redefines constants. A fresh
      # anonymous class re-running the mixin must still resolve to the same
      # origin-keyed pool from the registry.
      first  = service_class.connection_pool
      reload = Class.new do
        include HttpConnectionPool::Connectable

        self.base_url = 'https://api.internal.example.com'
      end

      expect(reload.connection_pool).to be(first)
    end
  end

  describe 'thread safety under ActiveSupport::Dependencies-style concurrency' do
    it 'hands the same pool to many threads racing through the registry' do
      registry = HttpConnectionPool::Registry.instance
      mutex    = Mutex.new
      pools    = []

      threads = Array.new(16) do
        Thread.new do
          pool = registry.pool_for('https://race.example.com')
          mutex.synchronize { pools << pool }
        end
      end
      threads.each(&:join)

      expect(pools.uniq.length).to eq(1)
    end
  end
end
