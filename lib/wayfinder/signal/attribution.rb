# frozen_string_literal: true

module Wayfinder
  module Signal
    # Remembers where somebody came from, on their first visit.
    #
    # This is the part that decides whether attribution works at all. Somebody
    # lands on /?utm_source=reddit, reads for a week, then fills in the form on
    # /contact — by which point the parameters are long gone from the URL and the
    # referrer is your own site. Reading them at the point of submission credits
    # almost everything to "direct", which is why so many attribution reports
    # look like nobody found you anywhere.
    #
    # So it is captured on the first request that carries anything, kept in a
    # cookie, and read back when a lead is finally submitted.
    #
    # First touch, not last. Somebody who arrives from a post, comes back a week
    # later through a retargeting ad and converts should credit the post — the ad
    # only caught somebody the post had already found.
    #
    # Nothing here talks to Wayfinder. It writes one cookie and reads parameters,
    # so it cannot fail, cannot block a request, and does nothing at all if
    # Wayfinder is unreachable.
    module Attribution
      extend ActiveSupport::Concern

      COOKIE = "wf_attribution"
      # Long enough for a considered B2B purchase, short enough to expire before
      # it is credited to something a year old.
      TTL = 90.days
      FIELDS = %w[source medium campaign content term referrer landing_page].freeze
      CLICK_IDS = %w[gclid fbclid msclkid ttclid].freeze
      MAX_LENGTH = 500

      included do
        before_action :capture_wayfinder_attribution
        helper_method :wayfinder_attribution if respond_to?(:helper_method)
      end

      # Everything known about where this person came from, ready to send with a
      # lead. Empty when they arrived with nothing, which is honest.
      def wayfinder_attribution
        @wayfinder_attribution ||= begin
          stored = cookies[COOKIE].presence
          stored ? JSON.parse(stored) : {}
        rescue JSON::ParserError
          {}
        end
      end

      private
        def capture_wayfinder_attribution
          return if cookies[COOKIE].present?

          attribution = current_attribution
          return if attribution.empty?

          cookies[COOKIE] = {
            value: attribution.to_json, expires: TTL.from_now,
            httponly: true, same_site: :lax, secure: request.ssl?
          }
          @wayfinder_attribution = attribution
        rescue StandardError
          # Attribution is never worth an exception in somebody's request path.
          nil
        end

        def current_attribution
          found = {}

          FIELDS.each do |field|
            value = request.params["utm_#{field}"] || request.params[field]
            found[field] = value.to_s.first(MAX_LENGTH) if value.present?
          end

          CLICK_IDS.each do |id|
            found[id] = request.params[id].to_s.first(MAX_LENGTH) if request.params[id].present?
          end

          # An external referrer only. Our own pages are not a channel, and
          # recording them would make the first internal click look like the
          # source.
          referrer = external_referrer
          found["referrer"] = referrer if referrer

          # Worth keeping even with no source: which page somebody landed on says
          # a good deal about what they were looking for.
          found["landing_page"] = request.original_url.to_s.first(MAX_LENGTH) if found.any?

          found
        end

        def external_referrer
          referrer = request.referer.presence
          return nil if referrer.blank?

          host = URI.parse(referrer).host
          return nil if host.blank? || host == request.host

          referrer.first(MAX_LENGTH)
        rescue URI::InvalidURIError
          nil
        end
    end
  end
end
