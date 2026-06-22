# frozen_string_literal: true

require 'http_connection_pool'

Dir[File.join(__dir__, 'support', '**', '*.rb')].each { |f| require f }

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.order = :random
  config.warnings = true

  config.include_context 'with a stubbed HTTP client'
  config.include ThreadSafetyHelpers, :thread_safety
  config.include FiberHelpers, :fiber

  # Reset the global registry between examples so pools don't bleed across tests.
  config.after do
    HttpConnectionPool::Registry.reset!
  end
end
