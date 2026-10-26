# frozen_string_literal: true

require_relative "lib/sodaflex/version"

Gem::Specification.new do |spec|
  spec.name = "sodaflex"
  spec.version = SodaFlex::VERSION
  spec.authors = [ "John Chambers" ]
  spec.summary = "Send what happens in a Rails application to SodaFlex."
  spec.description = <<~DESCRIPTION.strip
    A deliberately small client for SodaFlex's event API. Events are signed with
    HMAC-SHA256, delivered asynchronously through Active Job, and carry a
    client-generated idempotency key so redelivery is a no-op. The gem never
    raises into the host application: if SodaFlex is unavailable, your
    application must not notice.
  DESCRIPTION
  spec.homepage = "https://github.com/johnchambers/sodaflex-ruby"
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
