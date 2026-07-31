# frozen_string_literal: true

namespace :wayfinder do
  namespace :signal do
    desc "Show the local Wayfinder Signal configuration"
    task status: :environment do
      diagnostics = Wayfinder::Signal.diagnostics

      puts "\nWayfinder Signal"
      diagnostics.each { |key, value| puts format("  %-16s %s", key, value.inspect) }

      unless diagnostics[:configured]
        puts "\n  Not configured. Set WAYFINDER_SIGNAL_ENDPOINT, WAYFINDER_PRODUCT_KEY"
        puts "  and WAYFINDER_SIGNING_SECRET, or configure them in an initializer."
      end
      puts
    end

    desc "Raise a real exception and check it reaches Wayfinder"
    task test_error: :environment do
      config = Wayfinder::Signal.config

      unless config.ready?
        abort "Wayfinder Signal is not configured. Run rake wayfinder:signal:status."
      end

      unless config.report_exceptions
        abort "Exception reporting is off. Set config.report_exceptions = true, or " \
              "unset WAYFINDER_REPORT_EXCEPTIONS if it is switched off there."
      end

      # Raised for real, so the backtrace and the cause are genuine rather than
      # constructed — those are the parts most likely to be wrong.
      error = begin
        begin
          raise ArgumentError, "the underlying cause"
        rescue StandardError
          raise Wayfinder::Signal::TestError, "Test error from wayfinder:signal:test_error"
        end
      rescue StandardError => e
        e
      end

      # Through Rails.error rather than straight to the gem, because that is the
      # path a real 500 takes: the subscriber has to be registered, and it is
      # registered at boot only when configuration is complete. Calling the gem
      # directly would skip the half most likely to be misconfigured.
      properties = nil
      original = Wayfinder::Signal.method(:track)
      Wayfinder::Signal.define_singleton_method(:track) do |name, **payload|
        properties = payload[:properties]
        original.call(name, **payload)
      end

      Rails.error.report(error, handled: false, severity: :error, context: {})

      Wayfinder::Signal.singleton_class.send(:remove_method, :track)

      if properties.nil?
        abort "Nothing was reported. Rails.error has no Wayfinder subscriber, which " \
              "means the gem was not configured when the application booted."
      end

      puts "\nReported #{properties[:exception_class]}"
      puts "  where:  #{properties[:origin]}"
      puts "  cause:  #{properties.dig(:causes, 0, :exception_class) || "none"}"
      puts "  frames: #{Array(properties[:location]).size}"
      puts "\nDelivery is enqueued, so it arrives once the queue runs it."
      puts "Look in Wayfinder under Ship then Errors.\n\n"
    end

    desc "Send a test event to Wayfinder and report the result synchronously"
    task test: :environment do
      config = Wayfinder::Signal.config

      unless config.ready?
        abort "Wayfinder Signal is not configured. Run rake wayfinder:signal:status."
      end

      envelope = Wayfinder::Signal::Envelope.build("integration.connected",
        properties: { source: "rake", gem_version: Wayfinder::Signal::VERSION })

      # Delivered inline rather than enqueued, so the result is visible here.
      result = Wayfinder::Signal::Client.new.deliver([ envelope ])

      if result.success?
        puts "Delivered. Wayfinder replied #{result.status}: #{result.body}"
      else
        puts "Delivery failed. status=#{result.status} error=#{result.error} body=#{result.body}"
        exit 1
      end
    end
  end
end
