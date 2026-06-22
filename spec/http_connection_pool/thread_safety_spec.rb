# frozen_string_literal: true

require 'spec_helper'
require 'concurrent/atomic/atomic_fixnum'

# A reusable barrier: all threads block on `await` until `count` threads have
# arrived, then all are released simultaneously. Safer than ConditionVariable
# for precise race-condition testing.
class CyclicBarrier
  def initialize(count)
    @count   = count
    @waiting = 0
    @mutex   = Mutex.new
    @cv      = ConditionVariable.new
  end

  def await
    @mutex.synchronize do
      @waiting += 1
      if @waiting >= @count
        @waiting = 0
        @cv.broadcast
      else
        @cv.wait(@mutex) until @waiting.zero?
      end
    end
  end
end

# These specs exercise the gem under real concurrent load. They are tagged
# :thread_safety so they can be run in isolation:
#   bundle exec rspec spec/http_connection_pool/thread_safety_spec.rb
#
# Each example uses raw Thread coordination (barriers, queues) and
# Concurrent::AtomicFixnum for race-condition-safe counters.
RSpec.describe 'Thread safety', :thread_safety do
  let(:fake_client) { instance_double(HTTP::Client, close: nil) }

  before do
    allow(HTTP).to receive(:persistent).and_return(fake_client)
    allow(fake_client).to receive(:is_a?).with(HTTP::Client).and_return(true)
    allow(fake_client).to receive(:kind_of?).with(HTTP::Client).and_return(true)
  end

  # ── Pool ──────────────────────────────────────────────────────────────────

  describe 'Pool' do
    subject(:pool) { HttpConnectionPool::Pool.new(origin: 'https://pool-safety.example.com:443', size: 5, timeout: 2.0) }

    after { pool.close }

    describe 'concurrent close' do
      it 'is idempotent when 10 threads call close simultaneously' do
        barrier = CyclicBarrier.new(10)
        threads = Array.new(10) do
          Thread.new do
            barrier.await
            pool.close
          end
        end
        threads.each(&:join)
        expect(pool).to be_closed
      end
    end

    describe 'stats integrity under concurrent checkouts' do
      it 'never reports checked_out outside [0, size]' do
        violations = Concurrent::AtomicFixnum.new(0)
        threads = Array.new(20) do
          Thread.new do
            10.times do
              pool.with do
                s = pool.stats
                violations.increment if s[:checked_out] > pool.size || s[:checked_out].negative?
              end
            end
          end
        end
        threads.each(&:join)
        expect(violations.value).to eq(0)
      end
    end
  end

  # ── Registry ─────────────────────────────────────────────────────────────

  describe 'Registry' do
    subject(:registry) { HttpConnectionPool::Registry.new }

    describe 'concurrent distinct-origin creation' do
      it 'creates 20 distinct open pools without races' do
        origins = Array.new(20) { |i| "https://origin-#{i}.example.com" }
        barrier = CyclicBarrier.new(20)
        pools   = Array.new(20)

        threads = Array.new(20) do |i|
          Thread.new do
            barrier.await
            pools[i] = registry.pool_for(origins[i])
          end
        end
        threads.each(&:join)

        expect(pools.all? { |p| p && !p.closed? }).to be true
        expect(pools.uniq.length).to eq(20)
      end
    end

    describe 'close_all racing with pool_for' do
      def requester_thread(registry, index, returned, closed_counter)
        Thread.new do
          5.times do
            pool = registry.pool_for("https://race-#{index}.example.com")
            closed_counter.increment if pool.closed?
            returned.increment
          end
        end
      end

      it 'never deadlocks and all returned pools are open' do
        returned = Concurrent::AtomicFixnum.new(0)
        closed_while_open = Concurrent::AtomicFixnum.new(0)

        closer = Thread.new do
          5.times do
            registry.close_all
            sleep 0.001
          end
        end

        requesters = Array.new(10) do |i|
          requester_thread(registry, i, returned, closed_while_open)
        end

        requesters.each(&:join)
        closer.join

        expect(returned.value).to eq(50)
        expect(closed_while_open.value).to eq(0)
      end
    end

    describe 'max_pools cap under concurrent racing creation' do
      it 'raises PoolLimitError and never panics or deadlocks' do
        capped  = HttpConnectionPool::Registry.new(max_pools: 3)
        errors  = Concurrent::AtomicFixnum.new(0)
        barrier = CyclicBarrier.new(10)

        threads = Array.new(10) do |i|
          Thread.new do
            barrier.await
            capped.pool_for("https://cap-race-#{i}.example.com")
          rescue HttpConnectionPool::Registry::PoolLimitError
            errors.increment
          end
        end
        threads.each(&:join)
        capped.close_all

        # At least some threads must have hit the cap and at least 3 pools created.
        expect(capped.stats.length).to be <= 3
        expect(errors.value).to be >= 7
      end
    end

    describe 'concurrent release and re-acquire' do
      it 'never returns a closed pool' do
        closed_returns = Concurrent::AtomicFixnum.new(0)

        threads = Array.new(10) do
          Thread.new do
            5.times do
              pool = registry.pool_for('https://release-race.example.com')
              closed_returns.increment if pool.closed?
              registry.release('https://release-race.example.com')
            end
          end
        end
        threads.each(&:join)

        expect(closed_returns.value).to eq(0)
      end
    end
  end

  # ── Connectable ──────────────────────────────────────────────────────────

  describe 'Connectable' do
    let(:client_class) do
      Class.new do
        include HttpConnectionPool::Connectable

        self.base_url  = 'https://connectable-safety.example.com'
        self.pool_size = 10
      end
    end

    describe 'memoization race on first access' do
      it 'returns the same pool to 30 threads racing on first connection_pool call' do
        barrier = CyclicBarrier.new(30)
        pools   = Array.new(30)

        threads = Array.new(30) do |i|
          Thread.new do
            barrier.await
            pools[i] = client_class.connection_pool
          end
        end
        threads.each(&:join)

        expect(pools.uniq.length).to eq(1)
        expect(pools.first).not_to be_closed
      end
    end

    describe 'release and re-acquire under concurrency' do
      it 'never returns a closed pool across 10 interleaving threads' do
        closed_returns = Concurrent::AtomicFixnum.new(0)

        threads = Array.new(10) do
          Thread.new do
            5.times do
              pool = client_class.connection_pool
              closed_returns.increment if pool.closed?
              client_class.release_connection_pool
            end
          end
        end
        threads.each(&:join)

        expect(closed_returns.value).to eq(0)
      end
    end
  end
end
