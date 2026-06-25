# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'HttpConnectionPool error hierarchy' do
  it 'roots every pool error at HttpConnectionPool::Error' do
    [HttpConnectionPool::PoolLimitError,
     HttpConnectionPool::TimeoutError,
     HttpConnectionPool::ClosedError,
     HttpConnectionPool::ConfigurationError,
     HttpConnectionPool::InvalidURLError,
     HttpConnectionPool::OptionKeyError].each do |klass|
      expect(klass.ancestors).to include(HttpConnectionPool::Error)
    end
  end

  it 'groups configuration errors under ConfigurationError' do
    expect(HttpConnectionPool::InvalidURLError.ancestors)
      .to include(HttpConnectionPool::ConfigurationError)
    expect(HttpConnectionPool::OptionKeyError.ancestors)
      .to include(HttpConnectionPool::ConfigurationError)
  end

  it 'keeps the legacy Pool and Registry constants as aliases' do
    expect(HttpConnectionPool::Pool::TimeoutError)
      .to equal(HttpConnectionPool::TimeoutError)
    expect(HttpConnectionPool::Pool::ClosedError)
      .to equal(HttpConnectionPool::ClosedError)
    expect(HttpConnectionPool::Registry::PoolLimitError)
      .to equal(HttpConnectionPool::PoolLimitError)
  end

  it 'lets a single rescue catch any pool-layer error' do
    caught = []
    [HttpConnectionPool::TimeoutError, HttpConnectionPool::ClosedError,
     HttpConnectionPool::PoolLimitError, HttpConnectionPool::InvalidURLError,
     HttpConnectionPool::OptionKeyError].each do |klass|
      raise klass, 'boom'
    rescue HttpConnectionPool::Error => e
      caught << e.class
    end
    expect(caught.length).to eq(5)
  end
end
