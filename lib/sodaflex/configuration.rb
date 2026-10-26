# frozen_string_literal: true

module SodaFlex
  class Configuration
    # Deliberately short. This runs inside a customer-facing request path's
    # background job; waiting on SodaFlex is never worth it.
    DEFAULT_OPEN_TIMEOUT = 2
    DEFAULT_READ_TIMEOUT = 3

    attr_accessor :endpoint, :brand_key, :signing_secret, :environment,
                  :enabled, :queue, :open_timeout, :read_timeout,
                  :release, :logger, :on_delivery_failure, :batch_size,
                  :report_exceptions, :ignore_exceptions,
                  :max_exceptions_per_minute

    # Property keys redacted before an event leaves the host application. The
    # server refuses these too, but redacting here means they never travel.
    attr_accessor :redact_keys

    def initialize
      @endpoint = setting("ENDPOINT", "SIGNAL_ENDPOINT")
      @brand_key = setting("BRAND_KEY", "PRODUCT_KEY")
      @signing_secret = setting("SIGNING_SECRET")
      @environment = defined?(::Rails) ? ::Rails.env.to_s : "development"
      @enabled = true
      @queue = :default
      @open_timeout = DEFAULT_OPEN_TIMEOUT
      @read_timeout = DEFAULT_READ_TIMEOUT
      @release = setting("RELEASE")
      @batch_size = 50
      # Off by default. Exception volume varies enormously between products,
      # so streaming every one to SodaFlex should be a deliberate choice.
      @report_exceptions = false
      # Added to the ones every Rails application raises while serving ordinary
      # traffic — see ExceptionReport::IGNORED.
      @ignore_exceptions = []
      # Per exception class. A crash loop must not become a queue full of
      # identical reports; the first thirty say everything the next thousand do.
      @max_exceptions_per_minute = 30
      @redact_keys = %w[
        password password_confirmation token access_token refresh_token
        secret api_key authorization card_number cvv cvc pan iban ssn
      ]
      @logger = defined?(::Rails) ? ::Rails.logger : nil
      @on_delivery_failure = nil
    end

    # What a brand is called on the other end. It was `product_key`, and a
    # product's initializer from before the rename still sets that.
    alias_method :product_key, :brand_key
    alias_method :product_key=, :brand_key=

    # Everything must be present before the gem will attempt a delivery.
    # A half-configured product should be silently inert, not noisy.
    def ready?
      enabled && endpoint.present? && brand_key.present? && signing_secret.present?
    end

    def events_url
      return nil if endpoint.blank?

      endpoint.to_s.chomp("/")
    end

    private
      # SODAFLEX_*, or the WAYFINDER_* name it had before the rename — read
      # for one version, so a product whose environment was set up for the old
      # gem keeps reporting when only the Gemfile changes.
      def setting(name, legacy = name)
        ENV["SODAFLEX_#{name}"].presence || ENV["WAYFINDER_#{legacy}"].presence
      end
  end
end
