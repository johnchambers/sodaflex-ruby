# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module SodaFlex
  # Delivers a batch of envelopes to SodaFlex over HTTPS.
  #
  # This class exists inside a revenue-generating application, so its most
  # important property is what it does NOT do: it never raises into the caller,
  # never blocks a web request, and never retries forever. SodaFlex being down
  # must be invisible to the product's customers.
  class Client
    Result = Struct.new(:status, :body, :error, keyword_init: true) do
      def success? = status.to_i.between?(200, 299)

      # 4xx other than 408/429 means the payload will never be accepted, so
      # retrying it just burns queue capacity.
      def retryable?
        return true if error
        return false if status.to_i.between?(400, 499) && ![ 408, 429 ].include?(status.to_i)

        true
      end
    end

    def initialize(config = SodaFlex.config)
      @config = config
    end

    def deliver(envelopes)
      return Result.new(status: 0, error: "not configured") unless config.ready?

      body = JSON.generate({ "events" => Array(envelopes) })
      timestamp = Time.now.to_i

      post(body, timestamp)
    rescue StandardError => e
      # Anything at all — DNS, TLS, JSON, a nil somewhere. It ends here.
      Result.new(status: 0, error: "#{e.class}: #{e.message}")
    end

    private
      attr_reader :config

      def post(body, timestamp)
        uri = URI.parse(config.events_url)
        request = Net::HTTP::Post.new(uri.path.presence || "/")
        request.body = body
        headers(timestamp, body).each { |key, value| request[key] = value }

        response = http(uri).request(request)
        Result.new(status: response.code.to_i, body: response.body)
      rescue Net::OpenTimeout, Net::ReadTimeout => e
        Result.new(status: 0, error: "timeout: #{e.class}")
      rescue StandardError => e
        Result.new(status: 0, error: "#{e.class}: #{e.message}")
      end

      def http(uri)
        Net::HTTP.new(uri.host, uri.port).tap do |client|
          client.use_ssl = uri.scheme == "https"
          client.open_timeout = config.open_timeout
          client.read_timeout = config.read_timeout
          client.write_timeout = config.read_timeout if client.respond_to?(:write_timeout=)
        end
      end

      def headers(timestamp, body)
        # SodaFlex reads these names first and the X-Wayfinder-* ones a gem
        # from before the rename still sends, so the two can be mid-upgrade
        # at once.
        {
          "Content-Type" => "application/json",
          "User-Agent" => "sodaflex/#{VERSION}",
          "X-SodaFlex-Brand-Key" => config.brand_key,
          "X-SodaFlex-Timestamp" => timestamp.to_s,
          "X-SodaFlex-Signature" => Signature.generate(
            body: body, timestamp: timestamp, secret: config.signing_secret
          ),
          "X-SodaFlex-Gem-Version" => VERSION,
          "X-SodaFlex-Environment" => config.environment.to_s,
          "X-SodaFlex-Release" => config.release,
          "X-SodaFlex-Rails-Version" => (::Rails.version if defined?(::Rails))
        }.compact
      end
  end
end
