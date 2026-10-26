# frozen_string_literal: true

namespace :sodaflex do
  desc "Show the local SodaFlex configuration"
  task status: :environment do
    diagnostics = SodaFlex.diagnostics

    puts "\nSodaFlex"
    diagnostics.each { |key, value| puts format("  %-16s %s", key, value.inspect) }

    unless diagnostics[:configured]
      puts "\n  Not configured. Set SODAFLEX_ENDPOINT, SODAFLEX_BRAND_KEY"
      puts "  and SODAFLEX_SIGNING_SECRET, or configure them in an initializer."
    end
    puts
  end

  desc "Raise a real exception and check it reaches SodaFlex"
  task test_error: :environment do
    config = SodaFlex.config

    unless config.ready?
      abort "SodaFlex is not configured. Run rake sodaflex:status."
    end

    unless config.report_exceptions
      abort "Exception reporting is off. Set config.report_exceptions = true, or " \
            "check the initializer if it is switched off there."
    end

    # Raised for real, so the backtrace and the cause are genuine rather than
    # constructed — those are the parts most likely to be wrong.
    error = begin
      begin
        raise ArgumentError, "the underlying cause"
      rescue StandardError
        raise SodaFlex::TestError, "Test error from sodaflex:test_error"
      end
    rescue StandardError => e
      e
    end

    # Through Rails.error rather than straight to the gem, because that is the
    # path a real 500 takes: the subscriber has to be registered, and it is
    # registered at boot only when configuration is complete. Calling the gem
    # directly would skip the half most likely to be misconfigured.
    properties = nil
    original = SodaFlex.method(:track)
    SodaFlex.define_singleton_method(:track) do |name, **payload|
      properties = payload[:properties]
      original.call(name, **payload)
    end

    Rails.error.report(error, handled: false, severity: :error, context: {})

    SodaFlex.singleton_class.send(:remove_method, :track)

    if properties.nil?
      abort "Nothing was reported. Rails.error has no SodaFlex subscriber, which " \
            "means the gem was not configured when the application booted."
    end

    puts "\nReported #{properties[:exception_class]}"
    puts "  where:  #{properties[:origin]}"
    puts "  cause:  #{properties.dig(:causes, 0, :exception_class) || "none"}"
    puts "  frames: #{Array(properties[:location]).size}"
    puts "\nDelivery is enqueued, so it arrives once the queue runs it."
    puts "Look in SodaFlex under Pulse, in the event explorer.\n\n"
  end

  desc "Send a test event to SodaFlex and report the result synchronously"
  task test: :environment do
    config = SodaFlex.config

    unless config.ready?
      abort "SodaFlex is not configured. Run rake sodaflex:status."
    end

    envelope = SodaFlex::Envelope.build("integration.connected",
      properties: { source: "rake", gem_version: SodaFlex::VERSION })

    # Delivered inline rather than enqueued, so the result is visible here.
    result = SodaFlex::Client.new.deliver([ envelope ])

    if result.success?
      puts "Delivered. SodaFlex replied #{result.status}: #{result.body}"
    else
      puts "Delivery failed. status=#{result.status} error=#{result.error} body=#{result.body}"
      exit 1
    end
  end
end

# The names these had before the rename, for one version — a deploy script or
# a habit that still runs `wayfinder:signal:test` keeps working.
namespace :wayfinder do
  namespace :signal do
    %w[status test test_error].each do |name|
      desc "Renamed to sodaflex:#{name}"
      task name => "sodaflex:#{name}"
    end
  end
end
