# frozen_string_literal: true

require 'spec_helper'

RSpec.describe HttpConnectionPool::Connectable do
  # ── include ────────────────────────────────────────────────────────────────

  describe 'when included into a class' do
    let(:client_class) do
      Class.new do
        include HttpConnectionPool::Connectable

        self.base_url  = 'https://api.example.com'
        self.pool_size = 3
      end
    end

    describe '.connection_pool' do
      it 'returns a Pool' do
        expect(client_class.connection_pool).to be_a(HttpConnectionPool::Pool)
      end

      it 'returns the same pool on repeated calls' do
        first = client_class.connection_pool
        expect(client_class.connection_pool).to be(first)
      end
    end

    describe '.with_connection' do
      it 'yields an HTTP::Client to the block' do
        client_class.with_connection do |conn|
          expect(conn).to be_a(HTTP::Client)
        end
      end

      it 'returns the value from the block' do
        result = client_class.with_connection { |_c| :success }
        expect(result).to eq(:success)
      end
    end

    describe '.release_connection_pool' do
      it 'closes the pool' do
        pool = client_class.connection_pool
        client_class.release_connection_pool
        expect(pool).to be_closed
      end

      it 'drops the memo so the next call returns a fresh, open pool' do
        first = client_class.connection_pool
        client_class.release_connection_pool

        second = client_class.connection_pool
        expect(second).not_to be(first)
        expect(second).not_to be_closed
      end
    end

    describe '.connection_pool_stats' do
      it 'returns a Hash' do
        expect(client_class.connection_pool_stats).to be_a(Hash)
      end
    end

    describe 'instance methods' do
      subject(:instance) { client_class.new }

      it '#with_connection delegates to the class pool' do
        instance.with_connection { |conn| expect(conn).to be_a(HTTP::Client) }
      end

      it '#connection_pool is the same as the class pool' do
        expect(instance.connection_pool).to be(client_class.connection_pool)
      end

      it '#connection_pool_stats is the same as the class stats' do
        expect(instance.connection_pool_stats).to eq(client_class.connection_pool_stats)
      end
    end

    describe 'when base_url is not set' do
      let(:bare_class) do
        Class.new do
          include HttpConnectionPool::Connectable
        end
      end

      it 'raises NotImplementedError' do
        expect { bare_class.connection_pool }
          .to raise_error(NotImplementedError, /base_url/)
      end
    end

    describe 'default pool configuration' do
      let(:default_class) do
        Class.new do
          include HttpConnectionPool::Connectable

          self.base_url = 'https://defaults.example.com'
        end
      end

      it 'uses Pool::DEFAULT_SIZE' do
        expect(default_class.pool_size).to eq(HttpConnectionPool::Pool::DEFAULT_SIZE)
      end

      it 'uses Pool::DEFAULT_TIMEOUT' do
        expect(default_class.pool_timeout).to eq(HttpConnectionPool::Pool::DEFAULT_TIMEOUT)
      end
    end
  end

  # ── extend ─────────────────────────────────────────────────────────────────

  describe 'when extended onto a module' do
    let(:api_module) do
      Module.new do
        extend HttpConnectionPool::Connectable

        self.base_url = 'https://module.example.com'
      end
    end

    it 'provides .with_connection' do
      api_module.with_connection { |conn| expect(conn).to be_a(HTTP::Client) }
    end

    it 'provides .connection_pool' do
      expect(api_module.connection_pool).to be_a(HttpConnectionPool::Pool)
    end
  end

  # ── inheritance ────────────────────────────────────────────────────────────

  describe 'subclassing a Connectable class' do
    let(:base_class) do
      Class.new do
        include HttpConnectionPool::Connectable

        self.base_url     = 'https://api.example.com'
        self.pool_size    = 5
        self.pool_options = { headers: { 'X-App' => 'base' } }
      end
    end

    let(:sub_class) do
      bc = base_class
      Class.new(bc) do
        self.pool_options = { headers: { 'Authorization' => 'Bearer sub-token' } }
      end
    end

    let(:bare_sub_class) do
      Class.new(base_class)
    end

    it 'inherits base_url from the parent' do
      expect(sub_class.base_url).to eq('https://api.example.com')
    end

    it 'inherits pool_size from the parent' do
      expect(sub_class.pool_size).to eq(5)
    end

    it 'uses its own pool_options rather than the parent class pool_options' do
      expect(sub_class.pool_options).to eq(headers: { 'Authorization' => 'Bearer sub-token' })
    end

    it 'gets a distinct pool from the parent class' do
      expect(sub_class.connection_pool).not_to be(base_class.connection_pool)
    end

    it 'sibling subclasses with different options get distinct pools' do
      sibling = Class.new(base_class) do
        self.pool_options = { headers: { 'Authorization' => 'Bearer sibling-token' } }
      end
      expect(sub_class.connection_pool).not_to be(sibling.connection_pool)
    end

    it 'a subclass with no overrides shares the parent class pool' do
      expect(bare_sub_class.connection_pool).to be(base_class.connection_pool)
    end

    it 'release_connection_pool closes only the subclass pool' do
      sub_pool    = sub_class.connection_pool
      parent_pool = base_class.connection_pool
      sub_class.release_connection_pool
      expect(sub_pool).to be_closed
      expect(parent_pool).not_to be_closed
    end
  end

  # ── isolation ──────────────────────────────────────────────────────────────

  describe 'two classes with different base_urls' do
    let(:class_a) do
      Class.new do
        include HttpConnectionPool::Connectable

        self.base_url = 'https://service-a.example.com'
      end
    end

    let(:class_b) do
      Class.new do
        include HttpConnectionPool::Connectable

        self.base_url = 'https://service-b.example.com'
      end
    end

    it 'get distinct pools' do
      expect(class_a.connection_pool).not_to be(class_b.connection_pool)
    end
  end

  describe 'two classes sharing the same base_url' do
    let(:shared_url) { 'https://shared.example.com' }

    let(:class_x) do
      url = shared_url
      Class.new do
        include HttpConnectionPool::Connectable

        self.base_url = url
      end
    end

    let(:class_y) do
      url = shared_url
      Class.new do
        include HttpConnectionPool::Connectable

        self.base_url = url
      end
    end

    it 'share the same underlying pool' do
      expect(class_x.connection_pool).to be(class_y.connection_pool)
    end
  end
end
