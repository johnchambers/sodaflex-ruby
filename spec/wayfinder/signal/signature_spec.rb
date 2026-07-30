# frozen_string_literal: true

RSpec.describe Wayfinder::Signal::Signature do
  let(:body) { '{"events":[{"id":"evt_1"}]}' }
  let(:timestamp) { 1_785_000_000 }
  let(:secret) { "a-signing-secret" }

  # A fixed vector. Wayfinder verifies with an independent implementation of the
  # same scheme, so if this value ever changes, every connected product breaks.
  # Changing it is a breaking change to the wire protocol, not a refactor.
  it "produces a stable signature for known inputs" do
    expect(described_class.generate(body: body, timestamp: timestamp, secret: secret))
      .to eq("v1=" + OpenSSL::HMAC.hexdigest("SHA256", secret, "#{timestamp}.#{body}"))
  end

  it "prefixes the scheme version" do
    signature = described_class.generate(body: body, timestamp: timestamp, secret: secret)

    expect(signature).to start_with("v1=")
    expect(signature.delete_prefix("v1=")).to match(/\A[0-9a-f]{64}\z/)
  end

  # The timestamp is inside the signed payload, which is what stops a captured
  # request being replayed with a fresh one.
  it "changes when the timestamp changes" do
    a = described_class.generate(body: body, timestamp: timestamp, secret: secret)
    b = described_class.generate(body: body, timestamp: timestamp + 1, secret: secret)

    expect(a).not_to eq(b)
  end

  it "changes when the body changes" do
    a = described_class.generate(body: body, timestamp: timestamp, secret: secret)
    b = described_class.generate(body: body + " ", timestamp: timestamp, secret: secret)

    expect(a).not_to eq(b)
  end

  it "changes when the secret changes" do
    a = described_class.generate(body: body, timestamp: timestamp, secret: secret)
    b = described_class.generate(body: body, timestamp: timestamp, secret: "another-secret")

    expect(a).not_to eq(b)
  end
end
