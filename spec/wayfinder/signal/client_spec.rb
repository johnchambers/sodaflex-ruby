# frozen_string_literal: true

RSpec.describe Wayfinder::Signal::Client do
  before { configure_signal }

  let(:envelope) { { "id" => "evt_1", "name" => "customer.created" } }

  def stub_response(code, body = "{}")
    allow_any_instance_of(Net::HTTP).to receive(:request)
      .and_return(Struct.new(:code, :body).new(code.to_s, body))
  end

  def capture_request
    captured = nil
    allow_any_instance_of(Net::HTTP).to receive(:request) do |_http, request|
      captured = request
      Struct.new(:code, :body).new("202", "{}")
    end
    described_class.new.deliver([ envelope ])
    captured
  end

  describe "the request it sends" do
    it "posts the events wrapped in a batch" do
      expect(JSON.parse(capture_request.body)).to eq({ "events" => [ envelope ] })
    end

    it "signs the exact body it sends" do
      request = capture_request
      expected = Wayfinder::Signal::Signature.generate(
        body: request.body,
        timestamp: request["X-Wayfinder-Timestamp"],
        secret: "a-signing-secret"
      )

      expect(request["X-Wayfinder-Signature"]).to eq(expected)
    end

    it "identifies the product and the gem" do
      request = capture_request

      expect(request["X-Wayfinder-Product-Key"]).to eq("wfk_test_abc123")
      expect(request["X-Wayfinder-Gem-Version"]).to eq(Wayfinder::Signal::VERSION)
      expect(request["Content-Type"]).to eq("application/json")
    end

    it "never puts the signing secret in a header" do
      expect(capture_request.to_hash.to_s).not_to include("a-signing-secret")
    end
  end

  describe "classifying the outcome" do
    it "treats 2xx as success" do
      stub_response(202)
      expect(described_class.new.deliver([ envelope ])).to be_success
    end

    it "retries a 500" do
      stub_response(500)
      result = described_class.new.deliver([ envelope ])

      expect(result).not_to be_success
      expect(result).to be_retryable
    end

    # A payload Wayfinder will never accept must not be retried into the void.
    it "does not retry a 401 or a 422" do
      [ 401, 422 ].each do |code|
        stub_response(code)
        expect(described_class.new.deliver([ envelope ])).not_to be_retryable
      end
    end

    it "does retry a 429 or a 408, which are temporary" do
      [ 429, 408 ].each do |code|
        stub_response(code)
        expect(described_class.new.deliver([ envelope ])).to be_retryable
      end
    end
  end

  # The guarantee the whole gem exists to keep: an unavailable Wayfinder must be
  # invisible to the application that depends on it.
  describe "when Wayfinder is unreachable" do
    it "returns a failure rather than raising, on a refused connection" do
      allow_any_instance_of(Net::HTTP).to receive(:request).and_raise(Errno::ECONNREFUSED)

      result = nil
      expect { result = described_class.new.deliver([ envelope ]) }.not_to raise_error
      expect(result.error).to include("ECONNREFUSED")
      expect(result).to be_retryable
    end

    it "returns a failure rather than raising, on a timeout" do
      allow_any_instance_of(Net::HTTP).to receive(:request).and_raise(Net::ReadTimeout)

      result = described_class.new.deliver([ envelope ])
      expect(result.error).to include("timeout")
      expect(result).to be_retryable
    end

    it "returns a failure rather than raising, on anything at all" do
      allow_any_instance_of(Net::HTTP).to receive(:request).and_raise(NoMethodError, "something odd")

      expect { described_class.new.deliver([ envelope ]) }.not_to raise_error
    end

    it "does nothing at all when not configured" do
      Wayfinder::Signal.reset!

      result = described_class.new.deliver([ envelope ])
      expect(result).not_to be_success
      expect(result.error).to eq("not configured")
    end
  end

  describe "timeouts" do
    it "keeps them short, because this runs inside somebody else's application" do
      expect(Wayfinder::Signal.config.open_timeout).to be <= 5
      expect(Wayfinder::Signal.config.read_timeout).to be <= 5
    end
  end
end
