# frozen_string_literal: true

module Catalog
  # National directory of Timber Creek Housing retailers, used to populate the
  # "choose your dealer" picker when a dealer sets up a Timber Creek feed. Same
  # job as ClaytonHomeCenterDirectory, different site.
  #
  # Timber Creek runs on the ManufacturedHomes.com platform, whose per-state
  # retailer pages (/{state}-manufactured-homes/) embed the COMPLETE retailer
  # record as the JSON marker array feeding their store-locator map:
  #
  #   var markers = [{"id":1982,"name":"Atchafalaya Homes","street":"…",
  #                   "city":"Carencro","state":"LA","zipcode":"70520",
  #                   "phone":"(337) 896-1110","websiteUrl":"…",
  #                   "lat":30.26,"lng":-92.01,"status":1,
  #                   "url":"/dealer/1982/atchafalaya-homes/carencro", …}]
  #
  # That is the authoritative source and it is parsed instead of the rendered
  # dealer rows: the rows carry a subset (no geo, no website, no status) and are
  # markup we would have to re-calibrate, while the marker array is data.
  #
  # ~14 state pages cover the footprint, so the whole directory is one cheap
  # crawl rather than a fetch per retailer. Cached in Settings (platform scope)
  # and refreshed weekly, matching the Clayton directory.
  #
  #   Catalog::TimberCreekDealerDirectory.search('atchafalaya')
  #   #=> [{ 'dealer_id' => 1982, 'name' => 'Atchafalaya Homes', 'city' => 'Carencro', … }]
  #
  # IDENTITY IS dealer_id, NOT slug. Timber Creek reuses a slug across locations
  # (Mobile Mansions trades in both Lafayette and Thibodaux as
  # /dealer/1975/mobile-mansions/lafayette and /dealer/5440/mobile-mansions/
  # thibodaux), so keying on slug would silently collapse two real dealerships
  # into one.
  class TimberCreekDealerDirectory
    include PoliteHttp

    SITE_ROOT      = 'https://www.timbercreekhousing.com'
    RETAILERS_PATH = '/authorized-retailers/'
    SETTING_KEY    = 'timber_creek_dealer_directory'
    CACHE_TTL      = 7.days
    CRAWL_DELAY    = 2

    # State pages are linked from /authorized-retailers/ as
    # /{state-slug}-manufactured-homes/.
    STATE_PATH_RE = %r{/([a-z][a-z-]*)-manufactured-homes/}i
    # The locator's marker array. Non-greedy up to the closing "];" that ends the
    # assignment, so trailing script content can't be swallowed.
    MARKERS_RE = /var\s+markers\s*=\s*(\[.*?\])\s*;/m
    DEALER_PATH_RE = %r{\A/dealer/(\d+)/([^/]+)/([^/?#]+)}i

    # Used only when /authorized-retailers/ is unreachable. Timber Creek's own
    # copy names the footprint; keep this in sync if they expand.
    FALLBACK_STATES = %w[
      alabama arkansas florida georgia illinois kentucky louisiana mississippi
      missouri north-carolina oklahoma south-carolina tennessee texas
    ].freeze

    class << self
      # Cached entries ONLY — never crawls inline, so a cold cache cannot block a
      # web request. Callers surface #stale? and enqueue the refresh job.
      def all
        cached = Setting.get('Platform', PlatformSetting::PLATFORM_SCOPE_ID, SETTING_KEY)
        cached.is_a?(Hash) ? Array(cached['entries']) : []
      end

      def loaded?
        all.any?
      end

      def stale?
        cached = Setting.get('Platform', PlatformSetting::PLATFORM_SCOPE_ID, SETTING_KEY)
        return true unless cached.is_a?(Hash) && cached['fetched_at'].present?

        Time.zone.parse(cached['fetched_at']) < CACHE_TTL.ago
      rescue StandardError
        true
      end

      # Rebuild from Timber Creek and persist. Returns the entry list.
      # Long-running — call from TimberCreekDirectoryRefreshJob, not a controller.
      #
      # An empty crawl KEEPS the previous cache: a site outage must not empty the
      # picker for everyone.
      def refresh!
        entries = new.crawl
        if entries.empty?
          return Array(Setting.get('Platform', PlatformSetting::PLATFORM_SCOPE_ID, SETTING_KEY)&.dig('entries'))
        end

        Setting.set('Platform', PlatformSetting::PLATFORM_SCOPE_ID, SETTING_KEY,
                    { 'fetched_at' => Time.current.utc.iso8601, 'entries' => entries })
        entries
      end

      # Typeahead for the picker. Matches name, city and slug so a dealer can
      # find themselves by whichever they know.
      def search(query, state: nil, limit: 25)
        rows = all
        rows = rows.select { |r| r['state'].to_s.casecmp?(state.to_s) } if state.present?

        q = query.to_s.strip.downcase
        unless q.empty?
          rows = rows.select do |r|
            %w[name city slug].any? { |f| r[f].to_s.downcase.include?(q) } ||
              r['dealer_id'].to_s == q
          end
        end

        rows.sort_by { |r| [r['name'].to_s, r['city'].to_s] }.first(limit)
      end

      def find_by_dealer_id(dealer_id)
        all.find { |r| r['dealer_id'].to_s == dealer_id.to_s }
      end

      def fetched_at
        ts = Setting.get('Platform', PlatformSetting::PLATFORM_SCOPE_ID, SETTING_KEY)&.dig('fetched_at')
        ts && Time.zone.parse(ts)
      rescue StandardError
        nil
      end
    end

    def crawl
      states = discover_states

      states.each_with_index.flat_map do |state, i|
        rows = entries_for_state(state)
        sleep CRAWL_DELAY if i < states.size - 1
        rows
      end.uniq { |e| e['dealer_id'] }
    rescue StandardError => e
      Rails.logger.error "[TimberCreekDealerDirectory] crawl failed: #{e.class}: #{e.message}"
      []
    end

    # Retailer records for one state page.
    def entries_for_state(state)
      html = http_get("#{SITE_ROOT}/#{state}-manufactured-homes/")
      return [] if html.blank?

      markers(html).filter_map { |rec| normalize(rec) }
    rescue StandardError => e
      Rails.logger.warn "[TimberCreekDealerDirectory] #{state} failed: #{e.class}: #{e.message}"
      []
    end

    # State slugs linked from the retailer landing page. Discovered rather than
    # hardcoded so a new state self-heals; FALLBACK_STATES covers the page being
    # unreachable.
    def discover_states(html = http_get("#{SITE_ROOT}#{RETAILERS_PATH}"))
      return FALLBACK_STATES if html.blank?

      html.scan(STATE_PATH_RE).flatten.map(&:downcase).uniq.presence || FALLBACK_STATES
    rescue StandardError
      FALLBACK_STATES
    end

    def markers(html)
      json = html.to_s[MARKERS_RE, 1]
      return [] if json.blank?

      Array(JSON.parse(json))
    rescue JSON::ParserError => e
      Rails.logger.warn "[TimberCreekDealerDirectory] marker JSON unparseable: #{e.message}"
      []
    end

    private

    # Marker record -> directory row. Field names mirror the Clayton directory so
    # the admin picker can render either without special-casing.
    def normalize(rec)
      return nil unless rec.is_a?(Hash)

      path = rec['url'].to_s
      m    = path.match(DEALER_PATH_RE)
      id   = rec['id'].presence || m&.[](1)
      return nil if id.blank? || m.nil?

      # status 0 is a delisted retailer the locator still ships; their dealer
      # page renders an empty shell, so subscribing to one would produce a
      # permanently zero-home source.
      return nil unless rec['status'].to_i == 1

      {
        'dealer_id'   => id.to_i,
        'slug'        => m[2],
        'name'        => rec['name'].to_s.strip.presence,
        'street'      => rec['street'].to_s.strip.presence,
        'city'        => rec['city'].to_s.strip.presence,
        'state'       => rec['state'].to_s.strip.presence,
        'postal_code' => rec['zipcode'].to_s.strip.presence,
        'phone'       => rec['phone'].to_s.strip.presence,
        'website_url' => rec['websiteUrl'].to_s.strip.presence,
        'logo_url'    => rec['search_result_icon'].to_s.strip.presence,
        'latitude'    => rec['lat'],
        'longitude'   => rec['lng'],
        # The adapter's base_url. Trailing slash included: the platform 301s the
        # unslashed form, and every redirect is a wasted request on each crawl.
        'url'         => "#{SITE_ROOT}#{path.sub(%r{/*\z}, '')}/"
      }.compact
    end
  end
end
