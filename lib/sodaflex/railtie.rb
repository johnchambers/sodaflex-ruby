# frozen_string_literal: true

module SodaFlex
  class Railtie < ::Rails::Railtie
    rake_tasks do
      load File.expand_path("../tasks/sodaflex.rake", __dir__)
    end

    # Reporting an exception to SodaFlex should never itself raise, and
    # should never fire in test runs.
    initializer "sodaflex.error_reporting" do
      config.after_initialize do
        next unless SodaFlex.config.ready?
        next unless SodaFlex.config.report_exceptions

        Rails.error.subscribe(ExceptionSubscriber.new)
      end
    end
  end

  # Opt-in bridge from Rails.error to SodaFlex. Off by default: exception volume
  # varies wildly between products and should be a deliberate choice.
  class ExceptionSubscriber
    def report(error, handled:, severity:, context:, source: nil)
      return if handled

      SodaFlex.exception_reported(error, severity: severity, source: source,
                                       context: context.slice(:controller, :action, :job_class))
    rescue StandardError
      nil
    end
  end
end
