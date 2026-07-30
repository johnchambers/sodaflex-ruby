# frozen_string_literal: true

RSpec.describe Wayfinder::Signal do
  describe "configuration" do
    it "is not ready until endpoint, key and secret are all set" do
      expect(described_class.config).not_to be_ready

      described_class.configure { |c| c.endpoint = "https://wayfinder.test/api/signal/events" }
      expect(described_class.config).not_to be_ready

      configure_signal
      expect(described_class.config).to be_ready
    end

    it "can be switched off without being unconfigured" do
      configure_signal(enabled: false)

      expect(described_class.config).not_to be_ready
    end

    it "reports its state without printing the secret" do
      configure_signal

      diagnostics = described_class.diagnostics
      expect(diagnostics[:configured]).to be(true)
      expect(diagnostics[:signing_secret]).to eq("set")
      expect(diagnostics.to_s).not_to include("a-signing-secret")
    end

    it "does not report exceptions unless asked" do
      expect(described_class.config.report_exceptions).to be(false)
    end
  end

  describe ".track" do
    before { configure_signal }

    it "enqueues an envelope" do
      expect { described_class.track("customer.created") }.to change { enqueued_jobs.size }.by(1)
      expect(enqueued_jobs.last[:job]).to eq(Wayfinder::Signal::DeliveryJob)
    end

    it "returns the envelope it enqueued" do
      envelope = described_class.track("customer.created", customer: "cus_1")

      expect(envelope["name"]).to eq("customer.created")
      expect(envelope["customer"]).to eq({ "external_id" => "cus_1" })
    end

    it "does nothing when not configured" do
      described_class.reset!

      expect(described_class.track("customer.created")).to be_nil
      expect(enqueued_jobs).to be_empty
    end
  end

  # Instrumentation must not be able to break the thing it is instrumenting.
  # If any of these fail, a bug in this gem can take down a customer's checkout.
  describe "the guarantee that this gem cannot break its host" do
    before { configure_signal }

    it "returns nil rather than raising when the envelope cannot be built" do
      allow(Wayfinder::Signal::Envelope).to receive(:build).and_raise("boom")

      expect { expect(described_class.track("customer.created")).to be_nil }.not_to raise_error
    end

    it "returns nil rather than raising when the queue is unavailable" do
      allow(Wayfinder::Signal::DeliveryJob).to receive(:perform_later)
        .and_raise(RuntimeError, "queue is down")

      expect { described_class.track("customer.created") }.not_to raise_error
    end

    it "does not raise when a record passed as a subject misbehaves" do
      hostile = Class.new do
        def public_id = raise("exploding record")
        def id = raise("exploding record")
      end.new

      expect { described_class.track("customer.created", subject: hostile) }.not_to raise_error
    end
  end

  describe "the local dead-letter handler" do
    before { configure_signal }

    it "hands exhausted deliveries to the configured callable" do
      captured = []
      described_class.config.on_delivery_failure = ->(events, reason) { captured << [ events, reason ] }

      described_class.dead_letter([ { "id" => "evt_1" } ], reason: "gave up")

      expect(captured.first.last).to eq("gave up")
    end

    it "falls back to logging when none is configured" do
      expect { described_class.dead_letter([], reason: "gave up") }.not_to raise_error
    end

    it "survives a handler that itself raises" do
      described_class.config.on_delivery_failure = ->(*) { raise "handler is broken too" }

      expect { described_class.dead_letter([], reason: "gave up") }.not_to raise_error
    end
  end

  describe "convenience methods" do
    before { configure_signal }

    it "maps to the documented event names" do
      customer = Struct.new(:public_id).new("cus_1")

      expect(described_class.customer_created(customer)["name"]).to eq("customer.created")
      expect(described_class.invoice_paid(customer)["name"]).to eq("invoice.paid")
      expect(described_class.trial_started(customer)["name"]).to eq("trial.started")
      expect(described_class.test_event["name"]).to eq("integration.connected")
    end

    it "sends an exception's class, message and location — never its bindings" do
      error = RuntimeError.new("something failed")
      error.set_backtrace([ "app/models/order.rb:42:in `place'" ])

      envelope = described_class.exception_reported(error)

      expect(envelope["properties"]).to include(
        "exception_class" => "RuntimeError", "message" => "something failed"
      )
      expect(envelope["properties"]["location"]).to eq([ "app/models/order.rb:42:in `place'" ])
    end
  end
end
