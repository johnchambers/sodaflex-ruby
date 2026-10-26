# frozen_string_literal: true

require "active_support"
# Required explicitly rather than assumed. Inside a Rails application all of
# these are loaded anyway, which is exactly why the omission went unnoticed
# until the gem was extracted and tested on its own.
require "active_support/core_ext/object/blank"
require "active_support/core_ext/string/access"   # String#first
require "active_support/core_ext/string/filters"  # String#truncate
require "active_support/core_ext/hash/except"
require "active_support/core_ext/hash/keys"    # symbolize_keys
require "active_support/concern"
require "active_support/core_ext/numeric/time"      # 90.days
require "active_job"

require_relative "sodaflex/version"
require_relative "sodaflex/configuration"
require_relative "sodaflex/signature"
require_relative "sodaflex/redactor"
require_relative "sodaflex/envelope"
require_relative "sodaflex/attribution"
require_relative "sodaflex/exception_report"
require_relative "sodaflex/exception_throttle"
require_relative "sodaflex/client"

# Sends what happens in a product to SodaFlex. It was `Wayfinder::Signal`;
# `require "wayfinder/signal"` still works for one version, and still finds
# this module under its old name.
module SodaFlex
  # Raised only by sodaflex:test_error, so a test error is obvious in SodaFlex
  # rather than looking like a real one somebody has to investigate.
  class TestError < StandardError; end

  Error = Class.new(StandardError)
  DeliveryFailed = Class.new(Error)
  PermanentlyRejected = Class.new(Error)

  class << self
    def configure
      yield config
      config
    end

    def config
      @config ||= Configuration.new
    end

    def reset!
      @config = Configuration.new
    end

    # The core API.
    #
    #   SodaFlex.track("customer.created",
    #     actor: current_user, subject: customer,
    #     properties: { plan: customer.plan_name })
    #
    # Returns the envelope that was enqueued, or nil if SodaFlex is disabled or
    # not configured. It never raises — instrumentation must not be able to
    # break the thing it is instrumenting.
    def track(name, actor: nil, subject: nil, customer: nil, properties: {},
              context: {}, occurred_at: nil)
      return nil unless config.ready?

      envelope = Envelope.build(
        name, actor: actor, subject: subject, customer: customer,
        properties: properties, context: context, occurred_at: occurred_at,
        config: config
      )

      enqueue(envelope)
      envelope
    rescue StandardError => e
      log(:error, "track(#{name}) failed: #{e.class}: #{e.message}")
      nil
    end

    # Convenience wrappers for the events worth instrumenting first. Each is a
    # thin call to #track — the taxonomy lives in SodaFlex, not here.
    def customer_created(customer, **properties)
      track("customer.created", subject: customer, customer: customer, properties: properties)
    end

    def customer_churned(customer, **properties)
      track("customer.churned", subject: customer, customer: customer, properties: properties)
    end

    def onboarding_completed(customer, **properties)
      track("onboarding.completed", subject: customer, customer: customer, properties: properties)
    end

    def trial_started(customer, **properties)
      track("trial.started", subject: customer, customer: customer, properties: properties)
    end

    def subscription_started(subscription, customer: nil, **properties)
      track("subscription.started", subject: subscription, customer: customer, properties: properties)
    end

    def subscription_cancelled(subscription, customer: nil, **properties)
      track("subscription.cancelled", subject: subscription, customer: customer, properties: properties)
    end

    def invoice_paid(invoice, customer: nil, **properties)
      track("invoice.paid", subject: invoice, customer: customer, properties: properties)
    end

    def invoice_failed(invoice, customer: nil, **properties)
      track("invoice.failed", subject: invoice, customer: customer, properties: properties)
    end

    def feature_used(user, feature:, **properties)
      track("feature.used", actor: user, properties: properties.merge(feature: feature))
    end

    def key_action_completed(user, action:, customer: nil, **properties)
      track("key_action.completed", actor: user, customer: customer,
                                    properties: properties.merge(action: action))
    end

    def support_requested(customer, message:, **properties)
      track("support.conversation_started", customer: customer,
                                            properties: properties.merge(message: message.to_s.truncate(2_000)))
    end

    # Somebody showed interest. `attribution` is whatever Attribution captured
    # on their first visit, which is why it is a separate argument: it is not
    # something the caller assembles, it is something they pass through.
    def lead_created(attribution: {}, **properties)
      track("lead.created", properties: (attribution || {}).symbolize_keys.merge(properties))
    end

    def demo_requested(attribution: {}, **properties)
      track("demo.requested", properties: (attribution || {}).symbolize_keys.merge(properties))
    end

    def feature_requested(customer, request:, **properties)
      track("feature_request.created", customer: customer,
                                       properties: properties.merge(request: request.to_s.truncate(2_000)))
    end

    def release_deployed(release, **properties)
      track("deployment.succeeded", subject: release, properties: properties)
    end

    def deployment_failed(release, **properties)
      track("deployment.failed", subject: release, properties: properties)
    end

    # Sends the exception's class, message and backtrace — never its bindings
    # or local variables, which routinely contain customer data.
    #
    # Returns nil without sending anything when the exception is one Rails
    # raises in the ordinary course of serving traffic, or when that class has
    # already been reported enough times this minute. Both are silent on
    # purpose: they are the normal case, not a failure.
    def exception_reported(exception, **properties)
      return nil if ExceptionReport.ignored?(exception, config.ignore_exceptions)
      return nil unless exception_throttle.allow?(exception.class.name)

      track("exception.reported",
            properties: ExceptionReport.call(exception).merge(properties))
    end

    def exception_throttle
      @exception_throttle ||= ExceptionThrottle.new(limit: config.max_exceptions_per_minute)
    end

    # Sends a synthetic event so a new connection can be verified end to end
    # before any real instrumentation exists.
    def test_event
      track("integration.connected", properties: {
        source: "sodaflex", gem_version: VERSION, verified_at: Time.now.utc.iso8601
      })
    end

    def diagnostics
      {
        gem_version: VERSION,
        configured: config.ready?,
        endpoint: config.events_url,
        brand_key: config.brand_key&.then { |k| "#{k.to_s.first(12)}…" },
        signing_secret: config.signing_secret.present? ? "set" : "missing",
        environment: config.environment,
        enabled: config.enabled,
        queue: config.queue
      }
    end

    def log(level, message)
      config.logger&.public_send(level, "[sodaflex] #{message}")
    end

    # Called when delivery has finally given up. The default logs; a host app
    # can point this at a table, a file, or its own error reporter.
    def dead_letter(envelopes, reason:)
      if config.on_delivery_failure.respond_to?(:call)
        config.on_delivery_failure.call(envelopes, reason)
      else
        log(:error, "dropping #{Array(envelopes).size} event(s) after retries: #{reason}")
      end
    rescue StandardError => e
      log(:error, "dead-letter handler raised: #{e.class}: #{e.message}")
    end

    private
      def enqueue(envelope)
        DeliveryJob.perform_later([ envelope ])
      rescue StandardError => e
        # A broken queue must not break the request either.
        log(:error, "could not enqueue: #{e.class}: #{e.message}")
      end
  end
end

require_relative "sodaflex/delivery_job"
require_relative "sodaflex/railtie" if defined?(::Rails::Railtie)
