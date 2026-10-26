# frozen_string_literal: true

require "active_job"
require "sodaflex"

ActiveJob::Base.queue_adapter = :test
ActiveJob::Base.logger = Logger.new(IO::NULL)

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed

  # Configuration is global, so a leak between examples would make a later one
  # pass for the wrong reason.
  config.before { SodaFlex.reset! }

  config.include Module.new {
    def configure_signal(**overrides)
      SodaFlex.configure do |c|
        c.endpoint = overrides.fetch(:endpoint, "https://app.sodaflex.test/api/signal/events")
        c.brand_key = overrides.fetch(:brand_key, "wfk_test_abc123")
        c.signing_secret = overrides.fetch(:signing_secret, "a-signing-secret")
        c.environment = overrides.fetch(:environment, "test")
        c.logger = Logger.new(IO::NULL)
        overrides.except(:endpoint, :brand_key, :signing_secret, :environment)
          .each { |key, value| c.public_send(:"#{key}=", value) }
      end
    end
  }
end

# The gem does not depend on rspec-rails, so job assertions go through the
# Active Job test adapter directly rather than borrowing a Rails matcher.
module EnqueuedJobs
  def enqueued_jobs = ActiveJob::Base.queue_adapter.enqueued_jobs
end

RSpec.configure do |config|
  config.include EnqueuedJobs
  config.before { ActiveJob::Base.queue_adapter.enqueued_jobs.clear }
end
