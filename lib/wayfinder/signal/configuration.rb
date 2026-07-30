# frozen_string_literal: true

module Wayfinder
  module Signal
    class Configuration
      # Deliberately short. This runs inside a customer-facing request path's
      # background job; waiting on Wayfinder is never worth it.
      DEFAULT_OPEN_TIMEOUT = 2
      DEFAULT_READ_TIMEOUT = 3

      attr_accessor :endpoint, :product_key, :signing_secret, :environment,
                    :enabled, :queue, :open_timeout, :read_timeout,
                    :release, :logger, :on_delivery_failure, :batch_size,
                    :report_exceptions

      # Property keys redacted before an event leaves the host application. The
      # server refuses these too, but redacting here means they never travel.
      attr_accessor :redact_keys

      def initialize
        @endpoint = ENV["WAYFINDER_SIGNAL_ENDPOINT"]
        @product_key = ENV["WAYFINDER_PRODUCT_KEY"]
        @signing_secret = ENV["WAYFINDER_SIGNING_SECRET"]
        @environment = defined?(::Rails) ? ::Rails.env.to_s : "development"
        @enabled = true
        @queue = :default
        @open_timeout = DEFAULT_OPEN_TIMEOUT
        @read_timeout = DEFAULT_READ_TIMEOUT
        @release = ENV["WAYFINDER_RELEASE"]
        @batch_size = 50
        # Off by default. Exception volume varies enormously between products,
        # so streaming every one to Wayfinder should be a deliberate choice.
        @report_exceptions = false
        @redact_keys = %w[
          password password_confirmation token access_token refresh_token
          secret api_key authorization card_number cvv cvc pan iban ssn
        ]
        @logger = defined?(::Rails) ? ::Rails.logger : nil
        @on_delivery_failure = nil
      end

      # Everything must be present before the gem will attempt a delivery.
      # A half-configured product should be silently inert, not noisy.
      def ready?
        enabled && endpoint.present? && product_key.present? && signing_secret.present?
      end

      def events_url
        return nil if endpoint.blank?

        endpoint.to_s.chomp("/")
      end
    end
  end
end
