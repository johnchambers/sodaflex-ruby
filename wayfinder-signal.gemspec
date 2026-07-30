# frozen_string_literal: true

require_relative "lib/wayfinder/signal/version"

Gem::Specification.new do |spec|
  spec.name = "wayfinder-signal"
  spec.version = Wayfinder::Signal::VERSION
  spec.authors = [ "John Chambers" ]
  spec.summary = "Send operational events from a Rails application to Wayfinder."
  spec.description = <<~DESCRIPTION.strip
    A deliberately small client for Wayfinder's Signal ingestion API. Events are
    signed with HMAC-SHA256, delivered asynchronously through Active Job, and
    carry a client-generated idempotency key so redelivery is a no-op. The gem
    never raises into the host application: if Wayfinder is unavailable, your
    application must not notice.
  DESCRIPTION
  spec.homepage = "https://github.com/johnchambers/wayfinder-signal"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["rubygems_mfa_required"] = "true"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.files = Dir["lib/**/*.rb", "lib/**/*.rake", "README.md", "LICENSE.txt", "CHANGELOG.md"]
  spec.require_paths = [ "lib" ]

  # Deliberately minimal. No HTTP client dependency — Net::HTTP from the standard
  # library is enough, and adding faraday or httparty to somebody else's
  # application in order to send analytics would be a poor trade.
  spec.add_dependency "activejob", ">= 7.1"
  spec.add_dependency "activesupport", ">= 7.1"
end
