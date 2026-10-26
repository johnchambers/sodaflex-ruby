# frozen_string_literal: true

require "wayfinder/signal"

# The gem was wayfinder-signal. For one version a product set up for the old
# name keeps reporting with nothing changed but its Gemfile.
RSpec.describe "Renamed from wayfinder-signal" do
  around do |example|
    names = %w[SODAFLEX_ENDPOINT SODAFLEX_BRAND_KEY SODAFLEX_SIGNING_SECRET
               WAYFINDER_SIGNAL_ENDPOINT WAYFINDER_PRODUCT_KEY WAYFINDER_SIGNING_SECRET]
    saved = names.to_h { |name| [ name, ENV[name] ] }
    names.each { |name| ENV.delete(name) }
    example.run
  ensure
    saved.each { |name, value| value ? ENV[name] = value : ENV.delete(name) }
  end

  it "reads the SODAFLEX_* settings" do
    ENV["SODAFLEX_ENDPOINT"] = "https://app.sodaflex.com/api/signal/events"
    ENV["SODAFLEX_BRAND_KEY"] = "wfk_new"
    ENV["SODAFLEX_SIGNING_SECRET"] = "new-secret"

    expect(SodaFlex::Configuration.new).to be_ready
    expect(SodaFlex::Configuration.new.brand_key).to eq("wfk_new")
  end

  it "falls back to the WAYFINDER_* names an older environment still has" do
    ENV["WAYFINDER_SIGNAL_ENDPOINT"] = "https://app.sodaflex.com/api/signal/events"
    ENV["WAYFINDER_PRODUCT_KEY"] = "wfk_old"
    ENV["WAYFINDER_SIGNING_SECRET"] = "old-secret"

    config = SodaFlex::Configuration.new
    expect(config).to be_ready
    expect(config.brand_key).to eq("wfk_old")
  end

  it "prefers the new name when both are set, mid-upgrade" do
    ENV["SODAFLEX_BRAND_KEY"] = "wfk_new"
    ENV["WAYFINDER_PRODUCT_KEY"] = "wfk_old"

    expect(SodaFlex::Configuration.new.brand_key).to eq("wfk_new")
  end

  it "still answers to Wayfinder::Signal and product_key, from an initializer written for the old gem" do
    Wayfinder::Signal.configure { |config| config.product_key = "wfk_initializer" }

    expect(Wayfinder::Signal).to be(SodaFlex)
    expect(SodaFlex.config.brand_key).to eq("wfk_initializer")
  end
end
