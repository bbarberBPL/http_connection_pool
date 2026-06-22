# frozen_string_literal: true

require 'spec_helper'
require 'async'
require 'async/barrier'
require 'concurrent/promises'
require 'concurrent/atomic/atomic_fixnum'

# These specs verify two concurrency paths:
#
# 1. Fiber/Async scheduler — connection_pool >= 2.5 yields to the fiber
#    scheduler instead of parking the OS thread. A size-1 pool shared by
#    multiple concurrent fibers must not deadlock.
#
# 2. Concurrent::Promises — the concurrent-ruby thread-pool path. Futures
#    that raise inside with_connection must not leak checked-out connections.
#
# Run in isolation:
#   bundle exec rspec spec/http_connection_pool/fiber_spec.rb
RSpec.describe 'Fiber and Concurrent::Promises integration', :fiber do
  let(:fake_client) { instance_double(HTTP::Client, close: nil) }

  before do
    allow(HTTP).to receive(:persistent).and_return(fake_client)
    allow(fake_client).to receive(:is_a?).with(HTTP::Client).and_return(true)
    allow(fake_client).to receive(:kind_of?).with(HTTP::Client).and_return(true)
  end

  # ── Async / Fiber scheduler ───────────────────────────────────────────────

  describe 'Async fiber scheduler' do
    describe 'Pool under Async' do
      it 'completes 3 concurrent fibers sharing a size-1 pool without deadlock' do
        pool      = HttpConnectionPool::Pool.new(origin: 'https://fiber.example.com:443', size: 1, timeout: 3.0)
        completed = Concurrent::AtomicFixnum.new(0)

        Async do
          barrier = Async::Barrier.new
          3.times do
            barrier.async { pool.with { completed.increment } }
          end
          barrier.wait
        end

        pool.close
        expect(completed.value).to eq(3)
      end

      it 'completes N fibers sharing a size-N pool' do
        n         = 5
        pool      = HttpConnectionPool::Pool.new(origin: 'https://fiber-n.example.com:443', size: n, timeout: 3.0)
        completed = Concurrent::AtomicFixnum.new(0)

        Async do
          barrier = Async::Barrier.new
          n.times { barrier.async { pool.with { completed.increment } } }
          barrier.wait
        end

        pool.close
        expect(completed.value).to eq(n)
      end

      it 'returns all connections to the pool after all fibers complete' do
        pool = HttpConnectionPool::Pool.new(origin: 'https://fiber-return.example.com:443', size: 3, timeout: 3.0)

        Async do
          barrier = Async::Barrier.new
          3.times { barrier.async { pool.with { nil } } }
          barrier.wait
        end

        expect(pool.stats[:checked_out]).to eq(0)
        pool.close
      end
    end

    describe 'Registry under Async' do
      let(:local_registry) { HttpConnectionPool::Registry.new }

      after { local_registry.close_all }

      it 'returns the same pool to concurrent fibers racing on the same origin' do
        pools = Array.new(10)

        Async do
          barrier = Async::Barrier.new
          10.times do |i|
            barrier.async { pools[i] = local_registry.pool_for('https://fiber-race.example.com') }
          end
          barrier.wait
        end

        expect(pools.uniq.length).to eq(1)
      end
    end

    describe 'Connectable under Async' do
      it 'with_connection works correctly across 10 concurrent fibers' do
        allow(fake_client).to receive(:get).and_return(:ok)
        client_class = Class.new do
          include HttpConnectionPool::Connectable

          self.base_url  = 'https://fiber-connectable.example.com'
          self.pool_size = 5
        end

        results = Array.new(10)

        Async do
          barrier = Async::Barrier.new
          10.times do |i|
            barrier.async { results[i] = client_class.with_connection { |c| c.get('/status') } }
          end
          barrier.wait
        end

        expect(results).to all(eq(:ok))
      end
    end
  end

  # ── Concurrent::Promises ─────────────────────────────────────────────────

  describe 'Concurrent::Promises futures' do
    let(:pool) do
      HttpConnectionPool::Pool.new(origin: 'https://promises.example.com:443', size: 5, timeout: 3.0)
    end

    after { pool.close }

    it 'resolves 10 futures that each borrow a connection' do
      allow(fake_client).to receive(:get).and_return(:ok)
      futures = Array.new(10) do
        Concurrent::Promises.future { pool.with { |c| c.get('/') } }
      end
      results = Concurrent::Promises.zip(*futures).value!
      expect(results).to all(eq(:ok))
    end

    it 'does not leak a checked-out connection when a future raises' do
      allow(fake_client).to receive(:get).and_raise(RuntimeError, 'boom')

      future = Concurrent::Promises.future { pool.with { |c| c.get('/') } }
      future.wait

      expect(future).to be_rejected
      expect(pool.stats[:checked_out]).to eq(0)
    end
  end
end
