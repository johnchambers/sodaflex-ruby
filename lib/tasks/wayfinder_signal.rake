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
