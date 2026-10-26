# frozen_string_literal: true

RSpec.describe SodaFlex::Envelope do
  before { configure_signal(release: "2026.07.30.1") }

  def build(name = "customer.created", **options)
    described_class.build(name, **options)
  end

  describe "identifiers" do
    it "generates a prefixed ULID" do
      expect(build["id"]).to match(/\Aevt_[0-9A-HJKMNP-TV-Z]{26}\z/)
    end

    it "generates a distinct id for every envelope, which is what makes redelivery idempotent" do
      ids = Array.new(50) { build["id"] }

      expect(ids.uniq.size).to eq(50)
    end

    # Ordering is by the millisecond prefix. Two ids minted inside the same
    # millisecond have arbitrary relative order — the guarantee is chronological
    # ordering across time, not a strict total order.
    it "sorts chronologically across milliseconds" do
      earlier = described_class.ulid(Time.utc(2026, 7, 30, 12, 0, 0))
      later = described_class.ulid(Time.utc(2026, 7, 30, 12, 0, 1))

      expect([ later, earlier ].sort).to eq([ earlier, later ])
    end
  end

  describe "the envelope" do
    it "carries the name, version and environment" do
      envelope = build("invoice.paid")

      expect(envelope).to include("name" => "invoice.paid", "version" => 1, "environment" => "test")
    end

    it "stamps occurred_at and sent_at in ISO 8601 UTC" do
      envelope = build(occurred_at: Time.utc(2026, 7, 30, 12, 0, 0))

      expect(envelope["occurred_at"]).to eq("2026-07-30T12:00:00Z")
      expect(envelope["sent_at"]).to match(/\A\d{4}-\d{2}-\d{2}T.*Z\z/)
    end

    it "defaults occurred_at to now" do
      expect(Time.parse(build["occurred_at"])).to be_within(5).of(Time.now)
    end

    it "includes the configured release and gem version in context" do
      expect(build["context"]).to include("release" => "2026.07.30.1",
                                          "gem_version" => SodaFlex::VERSION)
    end

    it "omits keys that have no value rather than sending nulls" do
      expect(build.keys).not_to include("actor", "subject", "customer")
    end
  end

  describe "references" do
    # The most important property in here. Passing a record must never send that
    # record's attributes — only enough to identify it.
    it "sends a record's class and identifier, never its attributes" do
      customer_class = Struct.new(:id, :email, :name)
      stub_const("Customer", customer_class)
      envelope = build(subject: Customer.new(42, "ada@example.com", "Ada Lovelace"))

      expect(envelope["subject"]).to eq({ "type" => "Customer", "external_id" => "42" })
      expect(envelope.to_json).not_to include("ada@example.com", "Ada Lovelace")
    end

    it "prefers a public_id over a database id when the record has one" do
      record = Struct.new(:public_id, :id).new("cus_abc", 42)

      expect(build(subject: record)["subject"]["external_id"]).to eq("cus_abc")
    end

    it "accepts a bare identifier" do
      expect(build(customer: "cus_789")["customer"]).to eq({ "external_id" => "cus_789" })
    end

    it "accepts a hash, keeping only type and external_id" do
      envelope = build(actor: { type: "User", external_id: "usr_1", email: "leak@example.com" })

      expect(envelope["actor"]).to eq({ "type" => "User", "external_id" => "usr_1" })
      expect(envelope.to_json).not_to include("leak@example.com")
    end

    it "reduces a customer to its identifier alone" do
      envelope = build(customer: { "type" => "Customer", "external_id" => "cus_1" })

      expect(envelope["customer"]).to eq({ "external_id" => "cus_1" })
    end
  end

  describe "redaction" do
    it "drops configured keys before the envelope is built" do
      envelope = build(properties: { plan: "pro", password: "hunter2" })

      expect(envelope["properties"]).to eq({ "plan" => "pro" })
      expect(envelope.to_json).not_to include("hunter2")
    end

    it "records which names were dropped, so the misconfiguration stays visible" do
      envelope = build(properties: { password: "hunter2", api_key: "sk_live" })

      expect(envelope["context"]["redacted"]).to contain_exactly("password", "api_key")
    end

    it "says nothing about redaction when there was none" do
      expect(build(properties: { plan: "pro" })["context"]).not_to have_key("redacted")
    end
  end

  describe "properties" do
    it "stringifies keys so symbols and strings behave the same" do
      expect(build(properties: { plan: "pro" })["properties"]).to eq({ "plan" => "pro" })
    end

    it "tolerates nil properties and context" do
      expect { build(properties: nil, context: nil) }.not_to raise_error
    end
  end
end
