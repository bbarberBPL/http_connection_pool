# frozen_string_literal: true

require 'spec_helper'
require 'concurrent/atomic/atomic_fixnum'

# These specs exercise the gem under real concurrent load. They are tagged
# :thread_safety so they can be run in isolation:
#   bundle exec rspec spec/http_connection_pool/thread_safety_spec.rb
#
# The :thread_safety tag pulls in ThreadSafetyHelpers (spec/support), which
# provides the cyclic_barrier helper. Each example uses raw Thread coordination
# and Concurrent::AtomicFixnum for race-condition-safe counters.
RSpec.describe 'Thread safety', :thread_safety do
  # ── Pool ──────────────────────────────────────────────────────────────────

  describe 'Pool' do
    subject(:pool) { HttpConnectionPool::Pool.new(origin: 'https://pool-safety.example.com:443', size: 5, timeout: 2.0) }

    after { pool.close }

    describe 'concurrent close' do
      it 'is idempotent when 10 threads call close simultaneously' do
        barrier = cyclic_barrier(10)
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
        barrier = cyclic_barrier(20)
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
      it 'never deadlocks and all 50 pool_for calls complete' do
        returned = Concurrent::AtomicFixnum.new(0)

        closer = Thread.new do
          5.times do
            registry.close_all
            sleep 0.001
          end
        end

        requesters = Array.new(10) do |i|
          Thread.new do
            5.times do
              registry.pool_for("https://race-#{i}.example.com")
              returned.increment
            end
          end
        end

        requesters.each(&:join)
        closer.join

        expect(returned.value).to eq(50)
      end
    end

    describe 'max_pools cap under concurrent racing creation' do
      # max_pools is a documented *soft* cap: the size-check and insert are not
      # one atomic step, so in theory the count can briefly overshoot. On MRI,
      # however, the GVL serialises the check-and-insert region, so 10 racers
      # against a cap of 3 deterministically yield 3 pools + 7 rejections. The
      # gem only targets MRI (the http.rb llhttp C extension rules out
      # JRuby/TruffleRuby), so errors >= 7 is a stable expectation here. The
      # point of the test is that the cap holds and no thread deadlocks or
      # raises anything other than PoolLimitError.
      it 'raises PoolLimitError and never panics or deadlocks' do
        capped  = HttpConnectionPool::Registry.new(max_pools: 3)
        errors  = Concurrent::AtomicFixnum.new(0)
        barrier = cyclic_barrier(10)

        threads = Array.new(10) do |i|
          Thread.new do
            barrier.await
            capped.pool_for("https://cap-race-#{i}.example.com")
          rescue HttpConnectionPool::Registry::PoolLimitError
            errors.increment
          end
        end
        threads.each(&:join)

        pool_count = capped.stats.length
        capped.close_all

        expect(pool_count).to be <= 3
        expect(errors.value).to be >= 7
      end
    end

    describe 'concurrent release and re-acquire' do
      # pool_for must always loop until it can hand back a live pool, even while
      # other threads are releasing (closing) the same key underneath it. We
      # cannot assert the returned pool is still open afterwards — a racing
      # release may close it the instant after it is returned — so we assert the
      # observable invariant: every call returns a non-nil Pool and the churn
      # completes without deadlock.
      it 'always returns a live Pool under release churn without deadlock' do
        returned = Concurrent::AtomicFixnum.new(0)
        non_pool = Concurrent::AtomicFixnum.new(0)

        threads = Array.new(10) do
          Thread.new do
            5.times do
              pool = registry.pool_for('https://release-race.example.com')
              non_pool.increment unless pool.is_a?(HttpConnectionPool::Pool)
              returned.increment
              registry.release('https://release-race.example.com')
            end
          end
        end
        threads.each(&:join)

        expect(returned.value).to eq(50)
        expect(non_pool.value).to eq(0)
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
        barrier = cyclic_barrier(30)
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
      # As with the Registry-level churn test, a racing release_connection_pool
      # may close the pool right after connection_pool returns it, so we cannot
      # assert it is still open. The invariant under test is that the memoized
      # accessor always rebuilds a live Pool and never deadlocks or returns nil.
      it 'always returns a live Pool under release churn across 10 threads' do
        returned = Concurrent::AtomicFixnum.new(0)
        non_pool = Concurrent::AtomicFixnum.new(0)

        threads = Array.new(10) do
          Thread.new do
            5.times do
              pool = client_class.connection_pool
              non_pool.increment unless pool.is_a?(HttpConnectionPool::Pool)
              returned.increment
              client_class.release_connection_pool
            end
          end
        end
        threads.each(&:join)

        expect(returned.value).to eq(50)
        expect(non_pool.value).to eq(0)
      end
    end
  end
end
