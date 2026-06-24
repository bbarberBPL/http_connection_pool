# frozen_string_literal: true

require 'spec_helper'

# Exercises the Connectable pool inside background jobs. Sockets are stubbed
# (HTTP.persistent returns fake_client), so behaviour is asserted as registry
# invariants: pool counts, object counts, and checked-out counts.
RSpec.describe 'Background job integration', :background_jobs, :integration do
  before { allow(fake_client).to receive(:get).and_return(:ok) }

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
end
