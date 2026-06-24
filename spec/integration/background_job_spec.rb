# frozen_string_literal: true

require 'spec_helper'
require 'concurrent/atomic/atomic_fixnum'

# Exercises the Connectable pool inside background jobs. Sockets are stubbed
# (HTTP.persistent returns fake_client), so behaviour is asserted as registry
# invariants: pool counts, object counts, and checked-out counts.
RSpec.describe 'Background job integration', :background_jobs, :integration do
  before do
    allow(fake_client).to receive_messages(get: :ok, headers: fake_client)
  end

  describe 'bare Sidekiq::Job' do
    it 'borrows a pooled connection when performed inline' do
      JobHelpers::PoolJob.perform_async('/status')
      expect(HTTP).to have_received(:persistent).with('https://jobs.example.com:443')
    end
  end

  describe 'Active Job on the :test adapter' do
    it 'borrows a pooled connection when performed' do
      perform_active_job(JobHelpers::PoolActiveJob, '/status')
      expect(HTTP).to have_received(:persistent).with('https://jobs.example.com:443')
    end
  end

  describe 'Active Job on the :sidekiq adapter' do
    it 'borrows a pooled connection when performed inline' do
      JobHelpers::SidekiqAdapterActiveJob.perform_later('/status')
      expect(HTTP).to have_received(:persistent).with('https://jobs.example.com:443')
    end
  end

  describe 'pool sharing and survival across jobs' do
    it 'shares one pool across many sequential jobs against the same origin' do
      50.times { JobHelpers::PoolJob.perform_async('/status') }
      expect(registry.stats.length).to eq(1)
    end

    it 'reuses the same pool rather than rebuilding it per job' do
      50.times { JobHelpers::PoolJob.perform_async('/status') }
      # One persistent client built per pooled connection, never one per job.
      expect(HTTP).to have_received(:persistent).at_most(JobHelpers::PoolClient.pool_size).times
    end

    it 'hands every concurrent job a live pool without deadlock' do
      returned = Concurrent::AtomicFixnum.new(0)
      non_pool = Concurrent::AtomicFixnum.new(0)

      threads = Array.new(20) do
        Thread.new do
          pool = JobHelpers::PoolClient.connection_pool
          pool.is_a?(HttpConnectionPool::Pool) ? returned.increment : non_pool.increment
        end
      end
      threads.each(&:join)

      expect(returned.value).to eq(20)
      expect(non_pool.value).to eq(0)
    end
  end

  describe 'credential isolation across job classes' do
    it 'gives two job classes on the same host distinct pools' do
      JobHelpers::PoolJob.perform_async('/status')
      JobHelpers::AltPoolJob.perform_async('/status')

      expect(registry.stats.length).to eq(2)
    end

    it 'never shares a pool between the two job classes' do
      JobHelpers::PoolJob.perform_async('/status')
      JobHelpers::AltPoolJob.perform_async('/status')

      expect(JobHelpers::PoolClient.connection_pool)
        .not_to be(JobHelpers::AltPoolClient.connection_pool)
    end
  end

  describe 'exception path' do
    it 'returns the connection to the pool when a job raises mid-request' do
      20.times do
        expect { JobHelpers::RaisingJob.perform_async }.to raise_error(RuntimeError, 'boom')
      end

      expect(JobHelpers::PoolClient.connection_pool.stats[:checked_out]).to eq(0)
    end
  end
end
