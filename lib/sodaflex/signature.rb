# frozen_string_literal: true

require "openssl"

module SodaFlex
  # The signing scheme. SodaFlex implements the same algorithm server-side in
  # app/services/signals/signature.rb — if you change one, change both.
  #
  #   signed_payload = "#{timestamp}.#{raw_body}"
  #   signature      = "v1=" + HMAC-SHA256(signing_secret, signed_payload).hexdigest
  #
  # The timestamp is part of the signed payload, so a captured request cannot
  # be replayed with a fresh timestamp — the signature would stop matching.
  module Signature
    VERSION = "v1"

    def self.generate(body:, timestamp:, secret:)
      digest = OpenSSL::HMAC.hexdigest("SHA256", secret.to_s, "#{timestamp}.#{body}")
      "#{VERSION}=#{digest}"
    end
  end
end
