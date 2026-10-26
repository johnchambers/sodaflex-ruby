# frozen_string_literal: true

module SodaFlex
  # Removes configured keys before an event leaves the host application.
  #
  # Keys are *removed*, not blanked. SodaFlex refuses any payload containing a
  # forbidden key name at all, so leaving `"password" => "[redacted]"` in place
  # would make the event undeliverable — redaction would silently cost you the
  # whole event rather than just the field.
  #
  # The names that were dropped are returned so the envelope can record them in
  # context. That keeps the misconfiguration visible in SodaFlex without the
  # secret ever travelling.
  module Redactor
    MAX_DEPTH = 6

    Result = Struct.new(:value, :redacted_keys, keyword_init: true)

    def self.call(value, keys)
      dropped = []
      cleaned = scrub(value, keys, dropped, 0)

      Result.new(value: cleaned, redacted_keys: dropped.uniq)
    end

    def self.scrub(value, keys, dropped, depth)
      return value if depth > MAX_DEPTH

      case value
      when Hash
        value.each_with_object({}) do |(key, nested), result|
          if redact?(key, keys)
            dropped << key.to_s
          else
            result[key] = scrub(nested, keys, dropped, depth + 1)
          end
        end
      when Array
        value.map { |nested| scrub(nested, keys, dropped, depth + 1) }
      else
        value
      end
    end

    def self.redact?(key, keys)
      normalised = key.to_s.downcase
      keys.any? { |candidate| normalised.include?(candidate.to_s.downcase) }
    end
  end
end
