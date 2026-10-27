# frozen_string_literal: true

RSpec.describe SodaFlex::Redactor do
  let(:keys) { %w[password token secret] }

  def scrub(value) = described_class.call(value, keys)

  it "removes a matching key rather than blanking its value" do
    result = scrub({ "plan" => "pro", "password" => "hunter2" })

    expect(result.value).to eq({ "plan" => "pro" })
  end

  # SodaFlex refuses any payload containing a forbidden key name at all, so
  # leaving "password" => "[redacted]" in place would make the event
  # undeliverable — redaction would silently cost the whole event rather than
  # one field.
  it "leaves no trace of the key, only of its name" do
    result = scrub({ "password" => "hunter2" })

    expect(result.value.keys).to be_empty
    expect(result.redacted_keys).to eq([ "password" ])
    expect(result.value.to_s).not_to include("hunter2")
  end

  it "matches on substrings, so api_token and reset_password are caught" do
    result = scrub({ "api_token" => "x", "reset_password_url" => "y", "plan" => "keep" })

    expect(result.value).to eq({ "plan" => "keep" })
    expect(result.redacted_keys).to contain_exactly("api_token", "reset_password_url")
  end

  # "pan" is a card number; matched anywhere it took "company" off every lead
  # a brand sent, which is how Nibble's leads arrived without their business.
  it "matches a short name only as a whole part of the key" do
    result = described_class.call({ "company" => "keep", "card_pan" => "x", "panCode" => "y", "expansion" => "keep",
                     "cvv" => "z", "ssn_last4" => "w" }, %w[pan cvv ssn])

    expect(result.value).to eq({ "company" => "keep", "expansion" => "keep" })
    expect(result.redacted_keys).to contain_exactly("card_pan", "panCode", "cvv", "ssn_last4")
  end

  it "still matches a longer name anywhere in the key" do
    expect(described_class.call({ "userpassword" => "x", "stripeApiKey" => "y" }, %w[password api_key]).value)
      .to be_empty
  end

  it "is case insensitive" do
    expect(scrub({ "Password" => "x" }).value).to be_empty
  end

  it "reaches into nested hashes" do
    result = scrub({ "meta" => { "auth" => { "token" => "x", "scheme" => "bearer" } } })

    expect(result.value).to eq({ "meta" => { "auth" => { "scheme" => "bearer" } } })
    expect(result.redacted_keys).to eq([ "token" ])
  end

  it "reaches into arrays of hashes" do
    result = scrub({ "users" => [ { "name" => "Ada", "password" => "x" } ] })

    expect(result.value).to eq({ "users" => [ { "name" => "Ada" } ] })
  end

  it "reports each dropped name once, however often it appears" do
    result = scrub({ "a" => { "token" => 1 }, "b" => { "token" => 2 } })

    expect(result.redacted_keys).to eq([ "token" ])
  end

  # A guard against a cyclic or pathologically deep payload costing unbounded
  # work in somebody else's request path.
  it "stops descending past the depth limit" do
    deep = (1..12).reduce({ "password" => "leaked" }) { |inner, _| { "nest" => inner } }

    expect { scrub(deep) }.not_to raise_error
  end

  it "leaves values that are not collections alone" do
    expect(scrub("a string").value).to eq("a string")
    expect(scrub(42).value).to eq(42)
    expect(scrub(nil).value).to be_nil
  end

  it "reports nothing when there is nothing to remove" do
    expect(scrub({ "plan" => "pro" }).redacted_keys).to be_empty
  end
end
