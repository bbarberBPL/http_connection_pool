# frozen_string_literal: true

require 'sidekiq'
require 'sidekiq/testing'
require 'active_job'

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
