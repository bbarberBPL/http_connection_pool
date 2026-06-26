# frozen_string_literal: true

require 'spec_helper'

RSpec.describe HttpConnectionPool::Pool do
  subject(:pool) { described_class.new(origin: origin, size: 2, timeout: 1.0) }

  let(:origin) { 'https://api.example.com:443' }

  after { pool.close }

  describe '#initialize' do
    it 'stores the origin' do
      expect(pool.origin).to eq(origin)
    end

    it 'stores the size' do
      expect(pool.size).to eq(2)
    end

    it 'raises on size < 1' do
      expect { described_class.new(origin: origin, size: 0) }
        .to raise_error(ArgumentError, /size must be >= 1/)
    end

    it 'raises on non-positive timeout' do
      expect { described_class.new(origin: origin, timeout: 0) }
        .to raise_error(ArgumentError, /timeout must be > 0/)
    end
  end

  describe 'option immutability' do
    subject(:pool) do
      described_class.new(origin: origin, size: 1, timeout: 1.0,
                          headers: { 'Accept' => 'application/json' },
                          ssl: { ciphers: %w[a b] })
    end

    after { pool.close }

    it 'freezes the options hash' do
      expect(pool.instance_variable_get(:@options)).to be_frozen
    end

    it 'freezes nested option hashes' do
      headers = pool.instance_variable_get(:@options)[:headers]
      expect(headers).to be_frozen
    end

    it 'freezes nested option arrays' do
      ciphers = pool.instance_variable_get(:@options)[:ssl][:ciphers]
      expect(ciphers).to be_frozen
    end

    it 'raises when a caller mutates a nested option hash after pool creation' do
      headers = pool.instance_variable_get(:@options)[:headers]
      expect { headers['X'] = '1' }.to raise_error(FrozenError)
    end
  end

  describe 'credential redaction in #inspect / #to_s' do
    subject(:pool) do
      described_class.new(origin: origin, size: 2, timeout: 1.0,
                          headers: { 'Authorization' => 'Bearer SECRET-TOKEN' },
                          auth: 'Bearer SECRET-TOKEN')
    end

    it 'does not leak option values in #inspect' do
      expect(pool.inspect).not_to include('SECRET-TOKEN')
    end

    it 'does not leak option values in #to_s' do
      expect(pool.to_s).not_to include('SECRET-TOKEN')
    end

    it 'does not leak option values via pp / pretty_print' do
      require 'pp'
      require 'stringio'
      io = StringIO.new
      PP.pp(pool, io)
      expect(io.string).not_to include('SECRET-TOKEN')
    end

    it 'still shows option keys and non-sensitive state for debugging' do
      expect(pool.inspect).to include('headers', 'auth', origin, 'closed=false')
    end

    it 'shows options=[none] when no options were given' do
      bare = described_class.new(origin: origin, size: 1, timeout: 1.0)
      expect(bare.inspect).to include('options=[none]')
    end
  end

  describe '#with' do
    it 'yields an HTTP::Session' do
      pool.with do |conn|
        expect(conn).to be_a(HTTP::Session)
      end
    end

    it 'returns the block return value' do
      result = pool.with { |_conn| :ok }
      expect(result).to eq(:ok)
    end

    it 'returns the connection to the pool after the block' do
      pool.with { |_conn| nil }
      expect(pool.stats[:checked_out]).to eq(0)
    end

    it 'returns the connection even when the block raises' do
      expect { pool.with { raise 'boom' } }.to raise_error('boom')
      expect(pool.stats[:checked_out]).to eq(0)
    end

    context 'when the pool is exhausted' do
      subject(:tiny_pool) { described_class.new(origin: origin, size: 1, timeout: 0.1) }

      it 'raises TimeoutError after the timeout elapses' do
        barrier   = Mutex.new
        condition = ConditionVariable.new
        ready     = false

        # Thread 1 holds the only connection.
        t1 = Thread.new do
          tiny_pool.with do
            barrier.synchronize do
              ready = true
              condition.signal
            end
            sleep 0.5
          end
        end

        # Wait until Thread 1 has checked out.
        barrier.synchronize { condition.wait(barrier) until ready }

        # Thread 2 should time out.
        expect { tiny_pool.with { nil } }
          .to raise_error(HttpConnectionPool::Pool::TimeoutError)

        t1.join
        tiny_pool.close
      end
    end
  end

  describe '#close' do
    it 'marks the pool as closed' do
      pool.close
      expect(pool).to be_closed
    end

    it 'raises ClosedError on subsequent #with calls' do
      pool.close
      expect { pool.with { nil } }
        .to raise_error(HttpConnectionPool::Pool::ClosedError)
    end

    it 'is idempotent' do
      expect { 3.times { pool.close } }.not_to raise_error
    end

    it 'maps a mid-checkout shutdown to ClosedError, not the backing exception' do
      # Simulate the race where another thread shuts the backing pool down
      # after our #closed? guard passes but before/while we check out.
      allow(pool.instance_variable_get(:@pool))
        .to receive(:with).and_raise(ConnectionPool::PoolShuttingDownError)

      expect { pool.with { nil } }
        .to raise_error(HttpConnectionPool::Pool::ClosedError)
    end
  end

  describe '#stats' do
    it 'reports origin and size' do
      stats = pool.stats
      expect(stats[:origin]).to eq(origin)
      expect(stats[:size]).to eq(2)
    end

    it 'reports checked_out and closed in initial state' do
      stats = pool.stats
      expect(stats[:checked_out]).to eq(0)
      expect(stats[:closed]).to be false
    end

    it 'increments checked_out while a connection is borrowed' do
      in_block = Queue.new
      done     = Queue.new

      t = Thread.new do
        pool.with do
          in_block.push(:ready)
          done.pop
        end
      end

      in_block.pop
      expect(pool.stats[:checked_out]).to eq(1)
      done.push(:go)
      t.join
    end
  end

  # These exercise the REAL http.rb build path (no stub), so they verify that
  # apply_options produces a usable HTTP::Session on http v6 rather than raising.
  # HTTP.persistent / HTTP::Session#persistent build lazily, so no socket opens
  # until a request is made — constructing the connection is enough to assert on.
  describe 'building real connections (http v6 integration)' do
    def build(**options)
      real_pool = described_class.new(origin: origin, size: 1, timeout: 1.0, **options)
      created_pools << real_pool
      real_pool.send(:build_connection)
    end

    let(:created_pools) { [] }

    before do
      # Undo the global stubs so the real http.rb build path runs here.
      allow(HTTP::Session).to receive(:new).and_call_original
      allow(HTTP).to receive(:persistent).and_call_original
    end

    after { created_pools.each(&:close) }

    it 'yields a persistent HTTP::Session for a bare origin' do
      conn = build
      expect(conn).to be_a(HTTP::Session)
      expect(conn.persistent?).to be true
    end

    it 'applies header, auth, and timeout options without error' do
      conn = build(timeout: 5, headers: { 'Accept' => 'application/json' }, auth: 'Bearer x')
      expect(conn).to be_a(HTTP::Session)
      expect(conn.default_options.headers['Accept']).to eq('application/json')
    end

    # ssl_context: is rejected at the Registry boundary (OptionKeyError) because
    # an SSLContext cannot be safely used as a pool key. Pool.new itself does not
    # key options, so a directly-constructed pool can still seed ssl_context into
    # the session — but the supported path is the registry, so we assert the
    # rejection there rather than encouraging the direct-construction path.
    it 'rejects ssl_context at the registry boundary with OptionKeyError' do
      require 'openssl'
      ctx = OpenSSL::SSL::SSLContext.new
      registry = HttpConnectionPool::Registry.new
      expect { registry.pool_for(origin, ssl_context: ctx) }
        .to raise_error(HttpConnectionPool::OptionKeyError)
    ensure
      registry&.close_all
    end

    it 'applies an ssl hash option without error' do
      conn = build(ssl: { verify_mode: OpenSSL::SSL::VERIFY_NONE })
      expect(conn).to be_a(HTTP::Session)
      expect(conn.persistent?).to be true
    end

    it 'sets persistent to the origin as an options field' do
      conn = build
      expect(conn.default_options.persistent).to eq('https://api.example.com')
    end

    it 'folds auth into an Authorization header' do
      conn = build(auth: 'Bearer xyz')
      expect(conn.default_options.headers['Authorization']).to eq('Bearer xyz')
    end

    it 'merges auth with explicit headers rather than clobbering them' do
      conn = build(auth: 'Bearer xyz', headers: { 'Accept' => 'application/json' })
      expect(conn.default_options.headers['Accept']).to eq('application/json')
      expect(conn.default_options.headers['Authorization']).to eq('Bearer xyz')
    end

    it 'applies a proxy option without error' do
      conn = build(proxy: ['proxy.example.com', 8080])
      expect(conn).to be_a(HTTP::Session)
    end

    it 'resolves a relative request path against the persistent origin' do
      conn = build
      request = HTTP::Request::Builder.new(conn.default_options).build(:get, '/users/1')
      expect(request.uri.to_s).to eq('https://api.example.com/users/1')
    end
  end

  describe 'thread safety' do
    it 'allows concurrent checkouts up to pool size' do
      concurrency = 2
      threads_in  = Queue.new
      release     = Queue.new

      threads = Array.new(concurrency) do
        Thread.new do
          pool.with do
            threads_in.push(:in)
            release.pop
          end
        end
      end

      concurrency.times { threads_in.pop }
      expect(pool.stats[:checked_out]).to eq(concurrency)
      concurrency.times { release.push(:go) }
      threads.each(&:join)
    end

    it 'serialises access beyond pool size without deadlock' do
      tiny = described_class.new(origin: origin, size: 1, timeout: 2.0)
      results = Mutex.new
      log     = []

      threads = Array.new(3) do |i|
        Thread.new do
          tiny.with do
            results.synchronize { log << "enter-#{i}" }
            sleep 0.01
            results.synchronize { log << "exit-#{i}" }
          end
        end
      end

      threads.each(&:join)
      tiny.close

      # Each enter must be immediately followed by its own exit.
      log.each_slice(2).each do |enter, exit_ev|
        num = enter.split('-').last
        expect(exit_ev).to eq("exit-#{num}")
      end
    end
  end
end
