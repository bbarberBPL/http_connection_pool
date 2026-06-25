# frozen_string_literal: true

require 'spec_helper'

RSpec.describe HttpConnectionPool::Registry do
  subject(:registry) { described_class.new }

  describe '.instance' do
    it 'returns the same object on every call' do
      first = described_class.instance
      expect(described_class.instance).to be(first)
    end

    it 'is reset by .reset!' do
      first = described_class.instance
      described_class.reset!
      expect(described_class.instance).not_to be(first)
    end
  end

  describe '#pool_for' do
    it 'returns a Pool' do
      expect(registry.pool_for('https://api.example.com')).to be_a(HttpConnectionPool::Pool)
    end

    it 'normalises origins — same pool for paths under the same origin' do
      p1 = registry.pool_for('https://api.example.com/users/1')
      p2 = registry.pool_for('https://api.example.com/orders')
      expect(p1).to be(p2)
    end

    it 'returns distinct pools for different origins' do
      p1 = registry.pool_for('https://api.example.com')
      p2 = registry.pool_for('https://other.example.com')
      expect(p1).not_to be(p2)
    end

    it 'treats http and https as different origins' do
      p1 = registry.pool_for('http://api.example.com')
      p2 = registry.pool_for('https://api.example.com')
      expect(p1).not_to be(p2)
    end

    it 'treats different ports as different origins' do
      p1 = registry.pool_for('https://api.example.com:443')
      p2 = registry.pool_for('https://api.example.com:8443')
      expect(p1).not_to be(p2)
    end

    it 'replaces a closed pool transparently' do
      p1 = registry.pool_for('https://api.example.com')
      p1.close
      p2 = registry.pool_for('https://api.example.com')
      expect(p2).not_to be(p1)
      expect(p2).not_to be_closed
    end

    it 'raises InvalidURLError when the scheme is missing' do
      expect { described_class.new.pool_for('api.example.com') }
        .to raise_error(HttpConnectionPool::InvalidURLError, /scheme/)
    end

    it 'raises InvalidURLError for an unsupported scheme' do
      expect { described_class.new.pool_for('ftp://api.example.com') }
        .to raise_error(HttpConnectionPool::InvalidURLError, /unsupported scheme/)
    end

    it 'raises InvalidURLError when the host is missing' do
      expect { described_class.new.pool_for('https://') }
        .to raise_error(HttpConnectionPool::InvalidURLError, /host/)
    end

    context 'when the same origin is requested with different options' do
      it 'returns distinct pools for each unique option set' do
        p1 = registry.pool_for('https://api.example.com', headers: { 'Authorization' => 'Bearer aaa' })
        p2 = registry.pool_for('https://api.example.com', headers: { 'Authorization' => 'Bearer bbb' })
        expect(p1).not_to be(p2)
      end

      it 'reuses the pool when the options are identical' do
        opts = { headers: { 'Authorization' => 'Bearer same' } }
        p1 = registry.pool_for('https://api.example.com', **opts)
        p2 = registry.pool_for('https://api.example.com', **opts)
        expect(p1).to be(p2)
      end

      it 'allows a no-options pool alongside an options pool for the same origin' do
        p_bare    = registry.pool_for('https://api.example.com')
        p_auth    = registry.pool_for('https://api.example.com',
                                      headers: { 'Authorization' => 'Bearer token' })
        expect(p_bare).not_to be(p_auth)
      end
    end
  end

  describe '#release' do
    it 'closes and removes the no-options pool for the given URL' do
      pool = registry.pool_for('https://api.example.com')
      registry.release('https://api.example.com')
      expect(pool).to be_closed
    end

    it 'closes only the pool matching the given options' do
      opts    = { headers: { 'Authorization' => 'Bearer x' } }
      p_auth  = registry.pool_for('https://api.example.com', **opts)
      p_bare  = registry.pool_for('https://api.example.com')
      registry.release('https://api.example.com', **opts)
      expect(p_auth).to be_closed
      expect(p_bare).not_to be_closed
    end

    it 'is a no-op for an unknown URL' do
      expect { registry.release('https://unknown.example.com') }.not_to raise_error
    end
  end

  describe '#close_all' do
    it 'closes every registered pool' do
      p1 = registry.pool_for('https://api.example.com')
      p2 = registry.pool_for('https://other.example.com')
      registry.close_all
      expect(p1).to be_closed
      expect(p2).to be_closed
    end

    it 'is idempotent' do
      registry.pool_for('https://api.example.com')
      expect { 2.times { registry.close_all } }.not_to raise_error
    end
  end

  describe '#stats' do
    it 'returns an array of pool stats hashes' do
      registry.pool_for('https://api.example.com')
      stats = registry.stats
      expect(stats).to be_an(Array)
      expect(stats.first).to include(origin: 'https://api.example.com:443')
    end

    it 'includes one entry per distinct (origin, options) pool' do
      registry.pool_for('https://api.example.com')
      registry.pool_for('https://api.example.com', headers: { 'Authorization' => 'Bearer x' })
      expect(registry.stats.size).to eq(2)
    end
  end

  describe 'max_pools cap (unbounded-growth guard)' do
    it 'defaults to unlimited' do
      expect(described_class.new.max_pools).to be_nil
    end

    it 'validates the value' do
      expect { described_class.new(max_pools: 0) }
        .to raise_error(ArgumentError, /max_pools must be >= 1/)
    end

    it 'allows creating pools up to the cap' do
      capped = described_class.new(max_pools: 2)
      expect do
        capped.pool_for('https://a.example.com')
        capped.pool_for('https://b.example.com')
      end.not_to raise_error
    end

    it 'raises PoolLimitError when a new pool would exceed the cap' do
      capped = described_class.new(max_pools: 2)
      capped.pool_for('https://a.example.com')
      capped.pool_for('https://b.example.com')

      expect { capped.pool_for('https://c.example.com') }
        .to raise_error(HttpConnectionPool::Registry::PoolLimitError)
    end

    it 'counts origin+options combinations, not just origins' do
      capped = described_class.new(max_pools: 2)
      capped.pool_for('https://a.example.com')
      capped.pool_for('https://a.example.com', headers: { 'Authorization' => 'Bearer x' })

      expect { capped.pool_for('https://a.example.com', headers: { 'Authorization' => 'Bearer y' }) }
        .to raise_error(HttpConnectionPool::Registry::PoolLimitError)
    end

    it 'does not count reuse of an existing (origin, options) pair against the cap' do
      capped = described_class.new(max_pools: 1)
      capped.pool_for('https://a.example.com')

      expect { capped.pool_for('https://a.example.com') }.not_to raise_error
    end

    it 'frees a slot when a pool is released' do
      capped = described_class.new(max_pools: 1)
      capped.pool_for('https://a.example.com')
      capped.release('https://a.example.com')

      expect { capped.pool_for('https://b.example.com') }.not_to raise_error
    end

    it 'does not count a directly-closed pool against the cap' do
      capped = described_class.new(max_pools: 1)
      pool = capped.pool_for('https://a.example.com')
      pool.close # closed out-of-band, NOT via registry.release

      expect { capped.pool_for('https://b.example.com') }.not_to raise_error
    end
  end

  describe '#sweep_closed!' do
    it 'removes pools that were closed out-of-band and returns the count' do
      registry.pool_for('https://a.example.com')
      pool = registry.pool_for('https://b.example.com')
      pool.close

      swept = registry.sweep_closed!

      expect(swept).to eq(1)
      expect(registry.stats.size).to eq(1)
    end

    it 'leaves open pools untouched' do
      open_pool = registry.pool_for('https://a.example.com')
      registry.sweep_closed!

      expect(open_pool).not_to be_closed
      expect(registry.stats.size).to eq(1)
    end

    it 'returns 0 when there is nothing to sweep' do
      registry.pool_for('https://a.example.com')
      expect(registry.sweep_closed!).to eq(0)
    end
  end

  describe 'pool_key stability (hash key ordering)' do
    it 'treats options with the same keys in different order as the same pool' do
      p1 = registry.pool_for('https://api.example.com',
                             headers: { 'X-B' => '2', 'X-A' => '1' })
      p2 = registry.pool_for('https://api.example.com',
                             headers: { 'X-A' => '1', 'X-B' => '2' })
      expect(p1).to be(p2)
    end

    it 'treats top-level options with different key order as the same pool' do
      p1 = registry.pool_for('https://api.example.com', auth: 'tok', timeout: 5)
      p2 = registry.pool_for('https://api.example.com', timeout: 5, auth: 'tok')
      expect(p1).to be(p2)
    end
  end

  describe '#inspect / #to_s' do
    it 'does not expose pool keys or pool contents' do
      registry.pool_for('https://api.example.com',
                        headers: { 'Authorization' => 'Bearer SECRET' })
      expect(registry.inspect).not_to include('SECRET')
    end

    it 'shows pool count and cap' do
      registry.pool_for('https://api.example.com')
      expect(registry.inspect).to include('pools=1', 'max_pools=unlimited')
    end

    it 'shows the configured cap when max_pools is set' do
      capped = described_class.new(max_pools: 5)
      capped.pool_for('https://api.example.com')
      expect(capped.inspect).to include('max_pools=5')
    end

    it '#to_s matches #inspect' do
      expect(registry.to_s).to eq(registry.inspect)
    end
  end

  describe 'thread safety' do
    it 'returns the same pool when many threads request the same origin simultaneously' do
      barrier = Mutex.new
      start   = ConditionVariable.new
      go      = false
      pools   = Array.new(20)

      threads = Array.new(20) do |i|
        Thread.new do
          barrier.synchronize { start.wait(barrier) until go }
          pools[i] = registry.pool_for('https://concurrent.example.com')
        end
      end

      barrier.synchronize do
        go = true
        start.broadcast
      end
      threads.each(&:join)

      expect(pools.uniq.length).to eq(1)
    end
  end
end
