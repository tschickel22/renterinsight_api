# frozen_string_literal: true

module Catalog
  # The homes a source most recently parsed, kept so a new dealer subscribing
  # does not trigger a fresh crawl of data we already have.
  #
  # WHY THIS EXISTS
  # RunService parses every home, ingests it, then throws the result away. So
  # subscribing a second dealer next week re-crawls the whole source for
  # identical data. Measured against production runs that is 716s for Kabco,
  # 408s for Sunshine Homes, 375s for Clayton — each a full pass over the
  # vendor's site for nothing.
  #
  # Stored in platform Settings rather than Rails.cache: production has no
  # cache_store configured, so Rails.cache is per-instance file storage that is
  # neither shared across Render instances nor durable across deploys. The same
  # Setting-backed approach already carries a 336 KB Trove snapshot in prod.
  #
  # SELF-INVALIDATING: the payload records a fingerprint of the source's
  # base_url + config. Change either (rebind a snapshot, repoint a URL) and the
  # cache is treated as stale rather than silently serving data parsed under
  # the old settings.
  class ParsedHomeCache
    KEY_PREFIX  = 'catalog_parsed_homes'
    DEFAULT_TTL = 24.hours

    # How long a parse stays usable, mirroring CatalogSource#due? — crawling to
    # backfill a dealer more often than the source refreshes itself contradicts
    # the schedule. A weekly source asked to backfill on day 3 would otherwise
    # pay a full crawl (716s on Kabco) to produce data barely newer than the
    # cache.
    #
    # `manual` has no cadence at all: the admin has decided refreshes happen
    # when they say so, and Run Now always rewrites the cache. Capped anyway so
    # a forgotten source can't serve a year-old parse in silence.
    SCHEDULE_TTL = {
      'daily'  => 20.hours,
      'weekly' => 6.days,
      'manual' => 30.days
    }.freeze

    class << self
      def max_age_for(source)
        SCHEDULE_TTL.fetch(source.schedule.to_s, DEFAULT_TTL)
      end

      # @param max_age [ActiveSupport::Duration, nil] nil derives it from the
      #   source's own schedule.
      # @return [Array<NormalizedHome>, nil] nil when absent, stale, or parsed
      #   under different source settings.
      def read(source, max_age: nil)
        max_age ||= max_age_for(source)
        payload = raw(source)
        return nil if payload.blank?
        return nil unless payload['fingerprint'] == fingerprint(source)

        cached_at = parse_time(payload['cached_at'])
        return nil if cached_at.nil? || cached_at < max_age.ago

        homes = Array(payload['homes']).filter_map do |h|
          NormalizedHome.from_h(h) if h.is_a?(Hash)
        end
        homes.presence
      end

      def write(source, homes, degraded: false)
        homes = Array(homes)
        return if homes.empty?

        Setting.set('Platform', PlatformSetting::PLATFORM_SCOPE_ID, key_for(source),
                    { 'cached_at' => Time.current.utc.iso8601,
                      'fingerprint' => fingerprint(source),
                      'degraded' => !!degraded,
                      'count' => homes.size,
                      'homes' => homes.map(&:to_h) })
        homes.size
      rescue StandardError => e
        # A cache write must never sink a run that already succeeded.
        Rails.logger.warn "[Catalog::ParsedHomeCache] write failed for source #{source.id}: " \
                          "#{e.class}: #{e.message}"
        nil
      end

      # Was the cached parse itself degraded? Callers pass this to
      # IngestionService as protect_blanks so a thin parse cannot wipe good data.
      def degraded?(source)
        raw(source)&.dig('degraded') == true
      end

      def cached_at(source)
        parse_time(raw(source)&.dig('cached_at'))
      end

      def clear(source)
        Setting.set('Platform', PlatformSetting::PLATFORM_SCOPE_ID, key_for(source), nil)
      end

      def key_for(source)
        "#{KEY_PREFIX}:#{source.id}"
      end

      private

      def raw(source)
        value = Setting.get('Platform', PlatformSetting::PLATFORM_SCOPE_ID, key_for(source))
        value.is_a?(Hash) ? value : nil
      end

      def fingerprint(source)
        config = source.config.is_a?(Hash) ? source.config : {}
        Digest::SHA256.hexdigest([source.base_url, config.sort.to_json].join('|'))
      end

      def parse_time(value)
        value.present? ? Time.zone.parse(value.to_s) : nil
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
