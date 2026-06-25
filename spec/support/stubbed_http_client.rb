# frozen_string_literal: true

# Shared setup for the fake HTTP::Session used across every spec. On http v6,
# HTTP.persistent returns an HTTP::Session, so that is what we fake. Stubbing
# HTTP.persistent keeps tests from opening real sockets.
#
# Both is_a? AND kind_of? must be stubbed: RSpec's `be_a` matcher calls
# kind_of?, not is_a?, and a missing kind_of? stub fails silently. Centralising
# this here means no spec can get the pairing wrong.
RSpec.shared_context 'with a stubbed HTTP client' do
  let(:fake_client) { instance_double(HTTP::Session, close: nil) }

  before do
    allow(HTTP).to receive(:persistent).and_return(fake_client)
    allow(fake_client).to receive(:is_a?).with(HTTP::Session).and_return(true)
    allow(fake_client).to receive(:kind_of?).with(HTTP::Session).and_return(true)
  end
end
