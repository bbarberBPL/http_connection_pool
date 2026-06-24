# frozen_string_literal: true

require 'sidekiq'
require 'sidekiq/testing'
require 'active_job'

# Sidekiq 7.3 ships its own Active Job adapter
# (active_job/queue_adapters/sidekiq_adapter.rb) whose JobWrapper subclasses
# Sidekiq::ActiveJob::Wrapper. That wrapper is normally defined by
# sidekiq/rails.rb, which `require "rails"` -- the full Rails meta-gem, which is
# not a dependency of this gem. So we define the wrapper here with the exact
# body from sidekiq/rails.rb, letting the :sidekiq adapter resolve without
# booting a Rails engine.
module Sidekiq
  module ActiveJob
    class Wrapper
      include Sidekiq::Job

      def perform(job_data)
        ::ActiveJob::Base.execute(job_data.merge('provider_job_id' => jid))
      end
    end
  end
end

# Helpers and job classes for the background-job integration spec. Included
# into any example group tagged :background_jobs (wired in spec_helper.rb).
#
# Sidekiq runs in inline mode for these examples: enqueuing a job executes it
# synchronously in-process, exercising Sidekiq's worker/middleware path without
# Redis. Active Job uses its :test adapter, drained explicitly so we control
# exactly when jobs run.
module JobHelpers
  def self.included(base)
    base.before do
      Sidekiq::Testing.inline!
      ActiveJob::Base.queue_adapter = :test
      ActiveJob::Base.queue_adapter.enqueued_jobs.clear
      ActiveJob::Base.queue_adapter.performed_jobs.clear
    end

    base.after do
      Sidekiq::Testing.fake!
    end
  end

  class PoolClient
    include HttpConnectionPool::Connectable

    self.base_url  = 'https://jobs.example.com'
    self.pool_size = 5
  end

  class PoolJob
    include Sidekiq::Job

    def perform(path = '/x')
      PoolClient.with_connection { |conn| conn.get(path) }
    end
  end

  class AltPoolClient
    include HttpConnectionPool::Connectable

    self.base_url     = 'https://jobs.example.com'
    self.pool_size    = 5
    self.pool_options = { headers: { 'Authorization' => 'Bearer alt-token' } }
  end

  class AltPoolJob
    include Sidekiq::Job

    def perform(path = '/x')
      AltPoolClient.with_connection { |conn| conn.get(path) }
    end
  end

  class RaisingJob
    include Sidekiq::Job

    def perform
      PoolClient.with_connection { |_conn| raise 'boom' }
    end
  end

  class PoolActiveJob < ActiveJob::Base
    def perform(path = '/x')
      PoolClient.with_connection { |conn| conn.get(path) }
    end
  end

  class SidekiqAdapterActiveJob < ActiveJob::Base
    self.queue_adapter = :sidekiq
    def perform(path = '/x')
      PoolClient.with_connection { |conn| conn.get(path) }
    end
  end

  def registry
    HttpConnectionPool::Registry.instance
  end

  # Enqueue and immediately run an ActiveJob::Base subclass under the :test
  # adapter. perform_enqueued_jobs makes enqueued jobs execute synchronously.
  def perform_active_job(job_class, *)
    job_class.queue_adapter.perform_enqueued_jobs = true
    job_class.perform_later(*)
  ensure
    job_class.queue_adapter.perform_enqueued_jobs = false
  end
end
