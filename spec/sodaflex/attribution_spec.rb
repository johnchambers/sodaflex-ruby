# frozen_string_literal: true

require "spec_helper"

# The part that decides whether attribution works at all. Somebody lands on
# /?utm_source=reddit, reads for a week, then submits a form on /contact — by
# which point the parameters are gone and the referrer is your own site.
RSpec.describe SodaFlex::Attribution do
  # A stand-in for a Rails controller: the concern only touches params, cookies,
  # the referrer and the URL.
  let(:controller_class) do
    Class.new do
      # Defined before the include, because the concern registers a before_action
      # the moment it is mixed in.
      def self.before_action(*) = nil
      def self.helper_method(*) = nil

      include SodaFlex::Attribution

      attr_accessor :request, :cookies

      def initialize(params: {}, referer: nil, host: "nibble.ie",
                     url: "https://nibble.ie/", cookies: {})
        @cookies = cookies
        @request = Struct.new(:params, :referer, :host, :original_url, :ssl?)
          .new(params.transform_keys(&:to_s), referer, host, url, true)
      end

      def capture! = send(:capture_sodaflex_attribution)
    end
  end

  def capture(**options)
    controller = controller_class.new(**options)
    controller.capture!
    controller
  end

  describe "on the first visit" do
    it "keeps UTM parameters" do
      controller = capture(params: { utm_source: "reddit", utm_medium: "social",
                                     utm_campaign: "launch" })

      expect(controller.sodaflex_attribution).to include(
        "source" => "reddit", "medium" => "social", "campaign" => "launch"
      )
    end

    it "accepts them without the utm_ prefix too" do
      expect(capture(params: { source: "podcast" }).sodaflex_attribution["source"]).to eq("podcast")
    end

    it "keeps click identifiers, for reconciling with an ad platform later" do
      expect(capture(params: { gclid: "abc123" }).sodaflex_attribution["gclid"]).to eq("abc123")
    end

    it "keeps an external referrer" do
      controller = capture(referer: "https://chatgpt.com/c/123")

      expect(controller.sodaflex_attribution["referrer"]).to eq("https://chatgpt.com/c/123")
    end

    it "records the page they landed on, which says what they were after" do
      controller = capture(params: { utm_source: "reddit" }, url: "https://nibble.ie/for-takeaways")

      expect(controller.sodaflex_attribution["landing_page"]).to eq("https://nibble.ie/for-takeaways")
    end

    # Our own pages are not a channel. Without this the first internal click
    # looks like the source, and everything is attributed to the home page.
    it "ignores our own site as a referrer" do
      controller = capture(referer: "https://nibble.ie/pricing", host: "nibble.ie")

      expect(controller.sodaflex_attribution).to be_empty
    end

    it "records nothing when there is nothing to record" do
      controller = capture

      expect(controller.sodaflex_attribution).to be_empty
      expect(controller.cookies).to be_empty
    end
  end

  describe "first touch, not last" do
    # Somebody who arrives from a post, comes back through a retargeting ad and
    # converts should credit the post — the ad only caught somebody the post had
    # already found.
    it "does not overwrite what was captured first" do
      cookies = {}
      first = controller_class.new(params: { utm_source: "reddit" }, cookies: cookies)
      first.capture!
      cookies[described_class::COOKIE] = cookies[described_class::COOKIE][:value]

      second = controller_class.new(params: { utm_source: "retargeting" }, cookies: cookies)
      second.capture!

      expect(second.sodaflex_attribution["source"]).to eq("reddit")
    end

    # Somebody who first arrived while the product ran wayfinder-signal still
    # has the old cookie, and that visit is still their first.
    it "keeps a first touch recorded under the cookie's old name" do
      cookies = { described_class::LEGACY_COOKIE => { "source" => "reddit" }.to_json }
      controller = controller_class.new(params: { utm_source: "retargeting" }, cookies: cookies)
      controller.capture!

      expect(controller.sodaflex_attribution["source"]).to eq("reddit")
      expect(controller.wayfinder_attribution).to eq(controller.sodaflex_attribution)
      expect(cookies).not_to have_key(described_class::COOKIE)
    end
  end

  describe "the cookie" do
    it "is http-only and same-site, since nothing in the browser needs to read it" do
      controller = capture(params: { utm_source: "reddit" })
      cookie = controller.cookies[described_class::COOKIE]

      expect(cookie[:httponly]).to be(true)
      expect(cookie[:same_site]).to eq(:lax)
      expect(cookie[:secure]).to be(true)
    end

    it "expires, so a year-old visit is not credited with today's signup" do
      controller = capture(params: { utm_source: "reddit" })

      expect(controller.cookies[described_class::COOKIE][:expires]).to be_within(1.minute)
        .of(described_class::TTL.from_now)
    end
  end

  describe "safety" do
    it "reads an empty attribution rather than raising on a corrupt cookie" do
      controller = controller_class.new(cookies: { described_class::COOKIE => "not json" })

      expect(controller.sodaflex_attribution).to eq({})
    end

    it "truncates anything absurdly long" do
      controller = capture(params: { utm_campaign: "x" * 5_000 })

      expect(controller.sodaflex_attribution["campaign"].length).to eq(described_class::MAX_LENGTH)
    end

    # Attribution is never worth an exception in somebody's request path.
    it "does not raise when the referrer is not a URL" do
      expect { capture(referer: "::::") }.not_to raise_error
    end
  end
end
