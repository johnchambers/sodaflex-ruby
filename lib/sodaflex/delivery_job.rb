# frozen_string_literal: true

module SodaFlex
  # Delivery happens here, out of the request path.
  #
  # The job swallows every failure. An unhandled exception in a customer's
  # application because analytics was unavailable would be a serious bug, not
  # an acceptable trade-off. Exhausted deliveries go to the configured
  # dead-letter handler so they are still visible locally.
  class DeliveryJob < ActiveJob::Base
    MAX_ATTEMPTS = 5

    queue_as { SodaFlex.config.queue }

    # Bounded, with backoff. Retries stop; they do not accumulate forever.
    retry_on DeliveryFailed, wait: :polynomially_longer, attempts: MAX_ATTEMPTS do |job, error|
      SodaFlex.dead_letter(job.arguments.first, reason: error.message)
    end

    # A payload SodaFlex will never accept is dropped immediately rather than
    # retried into the void.
    discard_on PermanentlyRejected do |job, error|
      SodaFlex.dead_letter(job.arguments.first, reason: error.message)
    end

    def perform(envelopes)
      result = Client.new.deliver(envelopes)
      return if result.success?

      message = "status=#{result.status} #{result.error || result.body.to_s.first(200)}"
      SodaFlex.log(:warn, "delivery failed: #{message}")

      raise(result.retryable? ? DeliveryFailed : PermanentlyRejected, message)
    rescue DeliveryFailed, PermanentlyRejected
      raise
    rescue StandardError => e
      # Belt and braces. Nothing escapes this job.
      SodaFlex.log(:error, "unexpected delivery error: #{e.class}: #{e.message}")
      SodaFlex.dead_letter(envelopes, reason: "#{e.class}: #{e.message}")
      nil
    end
  end
end
