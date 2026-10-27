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

    # Shorter than this, a name must be a whole part of the key to match:
    # "pan" is a card number in `card_pan` and nothing at all in `company`,
    # which matching anywhere dropped from every lead. Longer names still match
    # anywhere, so `userpassword` stays caught — and camelCase is read as its
    # parts, so `stripeApiKey` is caught by `api_key` too.
    WHOLE_PART_BELOW = 5

    def self.redact?(key, keys)
      snake = key.to_s.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
      parts = snake.split(/[^a-z0-9]+/)

      keys.any? do |candidate|
        candidate = candidate.to_s.downcase
        candidate.length < WHOLE_PART_BELOW ? parts.include?(candidate) : snake.include?(candidate)
      end
    end
  end
end
