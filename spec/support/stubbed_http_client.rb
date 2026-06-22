# frozen_string_literal: true

# Shared setup for the fake HTTP::Client used across every spec. Stubbing
# HTTP.persistent keeps tests from opening real sockets.
#
# Both is_a? AND kind_of? must be stubbed: RSpec's `be_a` matcher calls
# kind_of?, not is_a?, and a missing kind_of? stub fails silently. Centralising
# this here means no spec can get the pairing wrong.
RSpec.shared_context 'with a stubbed HTTP client' do
  let(:fake_client) { instance_double(HTTP::Client, close: nil) }

  before do
    allow(HTTP).to receive(:persistent).and_return(fake_client)
    allow(fake_client).to receive(:is_a?).with(HTTP::Client).and_return(true)
    allow(fake_client).to receive(:kind_of?).with(HTTP::Client).and_return(true)
  end
end
