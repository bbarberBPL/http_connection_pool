# frozen_string_literal: true

# Shared setup for the fake HTTP::Session used across every spec. On http v6,
# the gem builds sessions via HTTP::Session.new (and HTTP.persistent routes
# through it), so we fake both seams to keep tests from opening real sockets.
#
# Both is_a? AND kind_of? must be stubbed: RSpec's `be_a` matcher calls
# kind_of?, not is_a?, and a missing kind_of? stub fails silently. Centralising
# this here means no spec can get the pairing wrong.
RSpec.shared_context 'with a stubbed HTTP client' do
  let(:fake_client) { instance_double(HTTP::Session, close: nil) }

  before do
    # HTTP::Session.new is the true build seam: the gem builds sessions via
    # HTTP::Session.new(HTTP::Options.new(...)), and HTTP.persistent itself
    # routes through branch -> HTTP::Session.new. Stub both so no spec opens a
    # real socket; the chainable methods return the fake so apply_chainable
    # (timeout/proxy) resolves.
    allow(HTTP::Session).to receive(:new).and_return(fake_client)
    allow(HTTP).to receive(:persistent).and_return(fake_client)
    allow(fake_client).to receive(:is_a?).with(HTTP::Session).and_return(true)
    allow(fake_client).to receive(:kind_of?).with(HTTP::Session).and_return(true)
    allow(fake_client).to receive_messages(timeout: fake_client, via: fake_client, headers: fake_client)
  end
end
