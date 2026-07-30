# frozen_string_literal: true

module Catalog
  # National directory of Clayton home centers (retailers), used to populate the
  # "choose your home center" picker when a dealer sets up a Clayton feed.
  #
  # Clayton's per-state location index pages embed the full retailer record in
  # their RSC flight payload — name, navigationSlug, address, geo, brand, and
  # inventory count. 43 state pages cover the whole country (~1,900 retailers),
  # so the directory is one cheap crawl rather than 1,900 page fetches.
  #
  # The result is cached in Settings (platform scope) because it changes slowly;
  # refresh weekly via CatalogNightlySyncJob or on demand from the admin UI.
  #
  #   Catalog::ClaytonHomeCenterDirectory.search('tyler', state: 'TX')
  #   #=> [{ 'slug' => 'mobile-home-masters-inc', 'name' => 'MOBILE HOME MASTERS INC', ... }]
  class ClaytonHomeCenterDirectory
    include ClaytonFlightPayload

    SITE_ROOT    = 'https://www.claytonhomes.com'
    SITEMAP_URL  = "#{SITE_ROOT}/sitemap.xml"
    SETTING_KEY  = 'clayton_home_center_directory'
    CACHE_TTL    = 7.days
    CRAWL_DELAY  = 2

    # State index pages live at /locations/{Capitalized-State}. Discovered from
    # the sitemap so a new state (or a rename) self-heals, with this list as the
    # fallback when the sitemap is unreachable.
    FALLBACK_STATES = %w[
      Alabama Arizona Arkansas California Colorado Delaware Florida Georgia Idaho
      Illinois Indiana Kansas Kentucky Louisiana Maine Maryland Michigan Minnesota
      Mississippi Missouri Montana Nebraska Nevada New-Hampshire New-Mexico New-York
      North-Carolina North-Dakota Ohio Oklahoma Oregon Pennsylvania South-Carolina
      South-Dakota Tennessee Texas Utah Vermont Virginia Washington West-Virginia
      Wisconsin Wyoming
    ].freeze

    class << self
      # Cached entries ONLY — never crawls inline. Walking 43 state pages with a
      # politeness delay takes minutes, so a cold cache must not block a web
      # request; callers surface #stale? and enqueue ClaytonDirectoryRefreshJob.
      def all
        cached = Setting.get('Platform', PlatformSetting::PLATFORM_SCOPE_ID, SETTING_KEY)
        cached.is_a?(Hash) ? Array(cached['entries']) : []
      end

      def loaded?
        all.any?
      end

      # True when the cache is missing or past its TTL and should be re-crawled.
      def stale?
        cached = Setting.get('Platform', PlatformSetting::PLATFORM_SCOPE_ID, SETTING_KEY)
        return true unless cached.is_a?(Hash) && cached['fetched_at'].present?

        Time.zone.parse(cached['fetched_at']) < CACHE_TTL.ago
      rescue StandardError
        true
      end

      # Rebuild from Clayton and persist. Returns the entry list. Long-running —
      # call from ClaytonDirectoryRefreshJob, not from a controller.
      def refresh!
        entries = new.crawl
        return Array(Setting.get('Platform', PlatformSetting::PLATFORM_SCOPE_ID, SETTING_KEY)&.dig('entries')) if entries.empty?

        Setting.set('Platform', PlatformSetting::PLATFORM_SCOPE_ID, SETTING_KEY,
                    { 'fetched_at' => Time.current.utc.iso8601, 'entries' => entries })
        entries
      end

      # Typeahead for the picker. Matches name, city, slug, and dealer number so a
      # dealer can find themselves by whichever they know.
      def search(query, state: nil, limit: 25)
        rows = all
        rows = rows.select { |r| r['state'].to_s.casecmp?(state.to_s) } if state.present?

        q = query.to_s.strip.downcase
        unless q.empty?
          rows = rows.select do |r|
            %w[name city slug dealer_number].any? { |f| r[f].to_s.downcase.include?(q) }
          end
        end

        rows.sort_by { |r| [r['name'].to_s, r['city'].to_s] }.first(limit)
      end

      def find_by_slug(slug)
        all.find { |r| r['slug'] == slug.to_s }
      end

      def fetched_at
        ts = Setting.get('Platform', PlatformSetting::PLATFORM_SCOPE_ID, SETTING_KEY)&.dig('fetched_at')
        ts && Time.zone.parse(ts)
      rescue StandardError
        nil
      end
    end

    def crawl
      sitemap = sitemap_body
      states  = discover_states(sitemap)

      entries = states.flat_map do |state|
        rows = entries_for_state(state)
        sleep CRAWL_DELAY if states.size > 1
        rows
      end.uniq { |e| e['slug'] }

      # State index pages are the rich source but can miss a retailer. The
      # sitemap is the wider list, so anything it names that no state page
      # covered gets resolved individually — the picker must never fail to find
      # a live dealer. Most of that tail is delisted retailers whose pages are
      # now empty shells; those resolve to nil and are dropped.
      backfill(entries, dealer_slugs_from_sitemap(sitemap))
    rescue StandardError => e
      Rails.logger.error "[ClaytonHomeCenterDirectory] crawl failed: #{e.class}: #{e.message}"
      []
    end

    # Individually resolve retailers absent from every state page.
    def backfill(entries, all_slugs)
      missing = all_slugs - entries.map { |e| e['slug'] }
      return entries if missing.empty?

      Rails.logger.info "[ClaytonHomeCenterDirectory] backfilling #{missing.size} unlisted retailers"
      resolved = missing.filter_map do |slug|
        row = entry_for_slug(slug)
        sleep CRAWL_DELAY
        row
      end
      Rails.logger.info(
        "[ClaytonHomeCenterDirectory] backfill resolved #{resolved.size}/#{missing.size}; " \
        "#{missing.size - resolved.size} are delisted (no HomeGoodsStore block)"
      )
      entries + resolved
    end

    # Build a directory row from one retailer page's schema.org store block.
    # Returns nil for a delisted retailer — its page renders a generic shell
    # carrying only Organization/WebSite metadata and no store record.
    def entry_for_slug(slug)
      html = http_get("#{SITE_ROOT}/locations/#{slug}")
      return nil if html.blank?

      store = Nokogiri::HTML(html)
                .css('script[type="application/ld+json"]')
                .filter_map { |n| JSON.parse(n.text) rescue nil }
                .find { |d| d['@type'] == 'HomeGoodsStore' }
      return nil unless store

      addr = store['address'] || {}
      flight_rec = decode_object_containing(flight_payload(html), '"dealerNumber":') || {}
      {
        'slug'          => slug,
        'name'          => titleize_name(store['name']),
        'dealer_id'     => flight_rec['dealerId'],
        'dealer_number' => flight_rec['dealerNumber'].to_s.presence,
        'brand'         => store['brand'].to_s.presence,
        'street'        => titleize_name(addr['streetAddress']),
        'city'          => titleize_name(addr['addressLocality']),
        'state'         => addr['addressRegion'].to_s.presence,
        'postal_code'   => addr['postalCode'].to_s.presence,
        'phone'         => store['telephone'].to_s.presence,
        'latitude'      => store.dig('geo', 'latitude'),
        'longitude'     => store.dig('geo', 'longitude'),
        'inventory_count' => nil,
        'url'           => "#{SITE_ROOT}/locations/#{slug}"
      }
    rescue StandardError => e
      Rails.logger.warn "[ClaytonHomeCenterDirectory] backfill #{slug} failed: #{e.message}"
      nil
    end

    # Retailer records for one state index page.
    def entries_for_state(state)
      html = http_get("#{SITE_ROOT}/locations/#{state}")
      return [] if html.blank?

      dealer_records(flight_payload(html)).filter_map { |rec| normalize(rec, state) }
    rescue StandardError => e
      Rails.logger.warn "[ClaytonHomeCenterDirectory] #{state} failed: #{e.class}: #{e.message}"
      []
    end

    private

    def sitemap_body
      http_get(SITEMAP_URL, accept: 'application/xml,text/xml').to_s
    end

    # State index slugs are the capitalised /locations/{State} sitemap entries.
    def discover_states(xml = sitemap_body)
      return FALLBACK_STATES if xml.blank?

      xml.scan(%r{/locations/([A-Z][A-Za-z-]+)/?<}).flatten.uniq.presence || FALLBACK_STATES
    rescue StandardError
      FALLBACK_STATES
    end

    # Lowercase /locations/{slug} sitemap entries — the retailer pages.
    def dealer_slugs_from_sitemap(xml)
      return [] if xml.blank?

      xml.scan(%r{/locations/([a-z0-9][a-z0-9-]*)/?<}).flatten.uniq
    rescue StandardError
      []
    end

    # Pull every object carrying a navigationSlug + dealerName out of the flight
    # payload. Scanning for the marker and decoding the enclosing object is more
    # tolerant of Next.js chunking than assuming a fixed container key.
    def dealer_records(flight)
      return [] if flight.blank?

      seen = {}
      flight.to_enum(:scan, /"navigationSlug":"/).each do
        idx = Regexp.last_match.begin(0)
        start = flight.rindex('{', idx)
        next unless start

        rec = decode_object(flight, start)
        next unless rec.is_a?(Hash) && rec['navigationSlug'].present? && rec['dealerName'].present?

        seen[rec['navigationSlug']] ||= rec
      end
      seen.values
    end

    def normalize(rec, state_slug)
      slug = rec['navigationSlug'].to_s.strip
      return nil if slug.blank?

      {
        'slug'          => slug,
        'name'          => titleize_name(rec['dealerName']),
        'dealer_id'     => rec['dealerId'],
        'dealer_number' => rec['dealerNumber'].to_s.presence,
        'brand'         => rec['brand'].to_s.presence,
        'street'        => titleize_name(rec['streetAddress']),
        'city'          => titleize_name(rec['city']),
        'state'         => rec['stateProvince'].to_s.presence || state_slug.tr('-', ' '),
        'postal_code'   => rec['postalCode'].to_s.presence,
        'phone'         => rec['phoneNumber'].to_s.presence,
        'latitude'      => rec['latitude'],
        'longitude'     => rec['longitude'],
        'inventory_count' => rec['numberInInventory'],
        'url'           => "#{SITE_ROOT}/locations/#{slug}"
      }
    end

    # Clayton ships these ALL CAPS; render them readably for the picker.
    def titleize_name(value)
      str = value.to_s.strip
      return nil if str.empty?
      return str unless str == str.upcase

      str.split(/(\s+)/).map { |part| part.match?(/\A\s+\z/) ? part : part.capitalize }.join
    end
  end
end
