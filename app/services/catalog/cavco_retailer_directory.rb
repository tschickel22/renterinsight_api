# frozen_string_literal: true

module Catalog
  # National directory of Cavco retailers, backing the "Add Cavco Dealer" picker.
  #
  # Unlike the Clayton directory, which had to crawl 43 state index pages over
  # ~2 minutes, Cavco indexes retailers as first-class documents in the same
  # search engine as the homes. The whole directory is a handful of paged
  # queries, so a refresh is quick enough to run inline — no background job.
  #
  # One directory covers every brand: palmharbor.com and friends link back to
  # cavcohomes.com retailer URLs, so this list is the family-wide roster.
  class CavcoRetailerDirectory
    SETTING_KEY = 'cavco_retailer_directory'
    CACHE_TTL   = 7.days
    SITE_ROOT   = 'https://www.cavcohomes.com'

    class << self
      # Cached rows only — never crawls inline, mirroring the Clayton directory
      # so the picker endpoint stays fast.
      def all
        cached = read
        cached.is_a?(Hash) ? Array(cached['entries']) : []
      end

      def loaded?
        all.any?
      end

      def stale?
        cached = read
        return true unless cached.is_a?(Hash) && cached['fetched_at'].present?

        Time.zone.parse(cached['fetched_at']) < CACHE_TTL.ago
      rescue ArgumentError, TypeError
        true
      end

      def fetched_at
        ts = read&.dig('fetched_at')
        ts && Time.zone.parse(ts)
      rescue StandardError
        nil
      end

      def refresh!
        entries = new.crawl
        return all if entries.empty? # never replace a good directory with nothing

        Setting.set('Platform', PlatformSetting::PLATFORM_SCOPE_ID, SETTING_KEY,
                    { 'fetched_at' => Time.current.utc.iso8601, 'entries' => entries })
        entries
      end

      def find_by_id(id)
        all.find { |e| e['id'] == id.to_s }
      end

      def search(query, state: nil, limit: 25)
        rows = all
        if state.present?
          want = state.to_s.upcase
          rows = rows.select { |e| e['state'].to_s.upcase == want }
        end

        if query.present?
          needle = query.to_s.downcase.strip
          rows = rows.select do |e|
            "#{e['name']} #{e['city']} #{e['state']} #{e['postal_code']}".downcase.include?(needle)
          end
        end

        rows.sort_by { |e| [e['state'].to_s, e['city'].to_s, e['name'].to_s] }.first(limit)
      end

      private

      def read
        value = Setting.get('Platform', PlatformSetting::PLATFORM_SCOPE_ID, SETTING_KEY)
        value.is_a?(Hash) ? value : nil
      end
    end

    def crawl
      entries = []
      client.each_document(filters: { 'type' => 'retailer' }) do |doc|
        row = normalize(doc)
        entries << row if row
      end
      entries.uniq { |e| e['id'] }
    rescue StandardError => e
      Rails.logger.error "[Catalog::CavcoRetailerDirectory] crawl failed: #{e.class}: #{e.message}"
      []
    end

    private

    def client
      @client ||= Catalog::CavcoSearchClient.new
    end

    def normalize(doc)
      id = doc['id'].to_s
      return nil if id.blank?

      name = doc['dba'].presence || doc['community'].presence
      return nil if name.blank?

      lat, lng = Array(doc['locations']).first.to_s.split(',')

      {
        'id'            => id,
        'name'          => name.to_s.strip,
        'location_id'   => doc['location_id'].to_s.presence,
        'location_type' => (doc['location_type_override'].presence || doc['location_type']).to_s.presence,
        'street'        => doc['address'].to_s.strip.presence,
        'city'          => doc['city'].to_s.strip.presence,
        'state'         => doc['state_or_province'].to_s.strip.upcase.presence,
        'postal_code'   => doc['zip'].to_s.strip.presence,
        'phone'         => doc['phone'].to_s.strip.presence,
        'latitude'      => lat.presence&.to_f,
        'longitude'     => lng.presence&.to_f,
        'url'           => absolute(doc['url'])
      }.compact
    end

    def absolute(path)
      return nil if path.blank?
      return path if path.to_s.start_with?('http')

      "#{SITE_ROOT}#{path}"
    end
  end
end
