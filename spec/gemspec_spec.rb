# frozen_string_literal: true

require 'rubygems'

RSpec.describe 'http_connection_pool.gemspec' do
  subject(:spec) do
    Gem::Specification.load(File.expand_path('../http_connection_pool.gemspec', __dir__))
  end

  it 'sets the RubyGems homepage' do
    expect(spec.homepage).to eq('https://rubygems.org/gems/http_connection_pool')
  end

  it 'mirrors the homepage into metadata' do
    expect(spec.metadata['homepage_uri']).to eq('https://rubygems.org/gems/http_connection_pool')
  end

  it 'points source_code_uri at the GitHub repo' do
    expect(spec.metadata['source_code_uri'])
      .to eq('https://github.com/bbarberBPL/http_connection_pool')
  end

  it 'requires MFA for privileged operations' do
    expect(spec.metadata['rubygems_mfa_required']).to eq('true')
  end
end
