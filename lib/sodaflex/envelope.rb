# frozen_string_literal: true

require "securerandom"

module SodaFlex
  # Builds the canonical event envelope.
  #
  # The `id` is generated here, in the host application, and is what makes
  # delivery idempotent: a retried request carries the same id, and SodaFlex's
  # unique index turns the second delivery into a no-op.
  class Envelope
    ENCODING = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

    def self.build(...) = new(...).to_h

    def initialize(name, actor: nil, subject: nil, customer: nil, properties: {},
                   context: {}, occurred_at: nil, config: SodaFlex.config)
      @name = name.to_s
      @actor = actor
      @subject = subject
      @customer = customer
      @properties = properties || {}
      @context = context || {}
      @occurred_at = occurred_at || Time.now
      @config = config
    end

    def to_h
      scrubbed_properties = Redactor.call(stringify(properties), config.redact_keys)
      scrubbed_context = Redactor.call(
        default_context.merge(stringify(context)), config.redact_keys
      )
      dropped = (scrubbed_properties.redacted_keys + scrubbed_context.redacted_keys).uniq

      if dropped.any?
        SodaFlex.log(:warn, "dropped #{dropped.join(', ')} from #{name} before sending")
      end

      {
        "id" => "evt_#{self.class.ulid}",
        "name" => name,
        "version" => 1,
        "occurred_at" => iso8601(occurred_at),
        "sent_at" => iso8601(Time.now),
        "environment" => config.environment,
        # Still `product_key` in the envelope: it is the server's contract, and
        # stored events carry it. Only the name a product configures changed.
        "product_key" => config.brand_key,
        "actor" => reference(actor),
        "subject" => reference(subject),
        "customer" => customer_reference,
        "properties" => scrubbed_properties.value,
        # Names only, never values — so the misconfiguration stays visible in
        # SodaFlex without the secret travelling. Safe because SodaFlex
        # scans key names, and these are values.
        "context" => scrubbed_context.value.merge(dropped.any? ? { "redacted" => dropped } : {})
      }.compact
    end

    # Same ULID scheme SodaFlex uses for its own identifiers, so event ids sort
    # in the order they were created.
    def self.ulid(now = Time.now)
      milliseconds = (now.to_f * 1000).floor
      encode(milliseconds, 10) + encode(SecureRandom.random_number(1 << 80), 16)
    end

    def self.encode(value, length)
      Array.new(length) { |i| ENCODING[(value >> (5 * (length - 1 - i))) & 0x1f] }.join
    end

    private
      attr_reader :name, :actor, :subject, :customer, :properties, :context,
                  :occurred_at, :config

      # Accepts a record, a hash, or a bare identifier. Records contribute their
      # class name and id and nothing else — never their attributes, which is
      # how arbitrary customer data would leak into an event stream.
      def reference(value)
        return nil if value.nil?

        case value
        when Hash
          stringify(value).slice("type", "external_id").presence
        when String, Integer
          { "external_id" => value.to_s }
        else
          { "type" => value.class.name, "external_id" => external_id_for(value) }.compact
        end
      end

      def customer_reference
        return nil if customer.nil?

        reference(customer)&.slice("external_id")&.presence
      end

      # `id` is tried before `to_param` deliberately. ActiveSupport defines
      # to_param on Object, where it returns to_s — so respond_to?(:to_param)
      # is always true, and for anything that is not an Active Record model it
      # yields the object's inspect string rather than an identifier. Inside a
      # Rails application that happens to work; on a plain object it produces
      # garbage, and would have shipped an entire record's contents as an
      # "external id".
      IDENTIFIER_METHODS = %i[public_id external_id id to_param].freeze
      MAX_IDENTIFIER_LENGTH = 255

      def external_id_for(record)
        IDENTIFIER_METHODS.each do |method|
          next unless record.respond_to?(method)

          value = begin
            record.public_send(method)
          rescue StandardError
            # A record whose identifier raises must not take the caller with it.
            next
          end
          next if value.blank?

          return value.to_s.first(MAX_IDENTIFIER_LENGTH)
        end
        nil
      end

      def default_context
        {
          "release" => config.release,
          "gem_version" => VERSION
        }.compact
      end

      def stringify(hash)
        return {} unless hash.respond_to?(:each_pair)

        hash.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
      end

      def iso8601(time)
        time.respond_to?(:utc) ? time.utc.iso8601 : Time.parse(time.to_s).utc.iso8601
      end
  end
end
