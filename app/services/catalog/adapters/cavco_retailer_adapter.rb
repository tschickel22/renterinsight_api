# frozen_string_literal: true

module Catalog
  module Adapters
    # One Cavco dealership's catalog, the same shape as the Clayton home center
    # adapter: platform admin picks a retailer, we derive everything else.
    #
    # Cavco assigns each retailer the models it may sell, and that assignment
    # already spans the whole family of brands — Amarillo Home Center carries
    # Solitaire, Palm Harbor and Cavco plant models in one list. So there is no
    # brand filtering to do: `retailer_ids` IS the dealer's catalog. A dealer
    # picking up a new brand simply appears on the next sync.
    #
    # The brand sites (palmharbor.com, fleetwoodhomes.com, …) are marketing
    # front-ends over the same directory — palmharbor.com's own retailer list
    # links back to cavcohomes.com URLs — so one adapter covers the family and
    # there is no per-brand source to add.
    #
    # Data comes from Elastic App Search rather than HTML: Cavco's pages are a
    # client-side SPA whose served markup is an empty shell.
    class CavcoRetailerAdapter < BaseAdapter
      SITE_ROOT = 'https://www.cavcohomes.com'

      SECTION_LABELS = {
        'single-wide' => 'Single Wide', 'singlewide' => 'Single Wide',
        'double-wide' => 'Double Wide', 'doublewide' => 'Double Wide',
        'triple-wide' => 'Triple Wide', 'triplewide' => 'Triple Wide'
      }.freeze

      TOUR_RE = %r{https?://(?:my\.)?(?:matterport\.com|momento360\.com)/[^\s"'<>)]+}i

      # One paged walk populates every document, so fetch is a lookup rather
      # than 165 more round trips. Test asks for a handful but still costs the
      # same two requests, which is cheaper than a request per sampled home.
      def discover(limit: nil)
        keys = documents.keys
        limit ? keys.first(limit) : keys
      end

      # discover() already pulled full documents, so fetch is a lookup rather
      # than a second request. Falls back to a targeted query if called cold.
      def fetch(key)
        cached = documents[key.to_s]
        return cached if cached

        response = client.search(filters: { 'all' => [{ 'type' => 'floorplan' }, { 'id' => key.to_s }] }, size: 1)
        doc = Array(response['results']).first
        doc && Catalog::CavcoSearchClient.flatten(doc)
      rescue StandardError => e
        Rails.logger.warn "[#{self.class.name}] fetch failed for #{key}: #{e.class}: #{e.message}"
        nil
      end

      def parse(raw)
        return nil if raw.blank?

        images = build_images(raw)

        NormalizedHome.new(
          source_key:      raw['id'],
          source_url:      absolute(raw['url']),
          model_name:      model_name_for(raw),
          model_id:        raw['model_number'].presence || raw['id'],
          series:          raw['series'].presence,
          property_type:   property_type_for(raw),
          bedrooms:        positive_int(raw['number_of_bedrooms']),
          bathrooms:       decimal(raw['number_of_bathrooms']),
          dimensions:      dimensions_for(raw),
          square_feet:     positive_int(raw['square_foot']),
          # Cavco publishes no prose description on floorplans — excused via
          # untracked_fields rather than synthesised.
          description:     nil,
          features:        features_for(raw),
          images:          images,
          virtual_tour_url: tour_for(raw),
          video_url:       raw['video_tour'].presence,
          raw:             raw_extras(raw)
        )
      end

      # Every home comes from one paged API walk, so there is nothing to be
      # polite about between models.
      def crawl_delay
        Integer(source.config['crawl_delay'] || 0)
      end

      def retailer_id
        source.config.is_a?(Hash) ? source.config.dig('retailer', 'id').presence || source.config['retailer_id'].presence : nil
      end

      # Surfaced on the admin Test action.
      def in_stock_count
        client.total_for('all' => [{ 'type' => 'inventory' }, { 'retailer_ids' => retailer_id }])
      rescue StandardError
        nil
      end

      def discovery_hint
        return 'No retailer is bound to this source — re-pick the dealership.' if retailer_id.blank?

        "Cavco returned no floorplans for retailer #{retailer_id}. The dealership may have been " \
          'delisted, or its assignments cleared.'
      end

      private

      def client
        @client ||= Catalog::CavcoSearchClient.new
      end

      def floorplan_filters
        raise Catalog::CavcoSearchClient::Error, 'no retailer_id configured' if retailer_id.blank?

        { 'all' => [{ 'type' => 'floorplan' }, { 'retailer_ids' => retailer_id }] }
      end

      # Every floorplan this retailer is assigned, keyed by Cavco's UUID.
      # Memoised for the life of the adapter — a run walks the pages once.
      def documents
        return @documents if defined?(@documents)

        @documents = begin
          store = {}
          client.each_document(filters: floorplan_filters) do |doc|
            id = doc['id'].to_s
            store[id] = doc if id.present?
          end
          store
        rescue StandardError => e
          Rails.logger.warn "[#{self.class.name}] document load failed: #{e.class}: #{e.message}"
          {}
        end
      end

      # ---- field extractors --------------------------------------------------

      # "Jasper" alone is ambiguous across plants; the model number disambiguates
      # and matches how the site labels cards ("Jasper 28564A").
      #
      # Note model_number is a FOOTPRINT code, not a unique model id — one
      # dealer carried 32563A four times as Victory Lane (Reserve), Cambridge
      # (Ovation), Cimarron (Ovation) and Hidden Shores (Banner), each a
      # different trim with its own square footage. That is real, so we keep the
      # manufacturer's number rather than inventing a synthetic one; the name
      # carries the distinction, and source_key (Cavco's UUID) is what ingestion
      # keys on, so vehicles never collide.
      def model_name_for(raw)
        [raw['name'].presence, raw['model_number'].presence].compact.join(' ').presence
      end

      def property_type_for(raw)
        label = SECTION_LABELS[raw['sections'].to_s.downcase.strip]
        types = []
        types << label if label
        method = raw['building_method'].to_s.strip
        types << method if method.present? && method != label
        types
      end

      # Cavco publishes BOTH sizes: the model number carries the nominal size
      # the trade quotes, while width/length_feet carry the built size. Jasper
      # 28564A measures 26'8" x 56' but is merchandised as 28x56, so the raw
      # measurement would put a number on the listing that no one recognises.
      #
      # Model numbers follow WWLLB + suffix (28564A = 28 wide, 56 long, 4 bed).
      # The bed digit is a free check on that reading — it agrees with
      # number_of_bedrooms on 59 of 60 sampled models — so decode only when it
      # matches, and fall back to the built size when it doesn't.
      MODEL_NUMBER_RE = /\A(\d{2})(\d{2})(\d)/

      def dimensions_for(raw)
        nominal_dimensions(raw) || built_dimensions(raw)
      end

      def nominal_dimensions(raw)
        match = raw['model_number'].to_s.match(MODEL_NUMBER_RE)
        return nil unless match

        beds = positive_int(raw['number_of_bedrooms'])
        return nil unless beds && match[3].to_i == beds

        width, length = match[1].to_i, match[2].to_i
        return nil unless width.positive? && length.positive?

        "#{width}x#{length}"
      end

      def built_dimensions(raw)
        w = rounded_feet(raw['width_feet'], raw['width_inches'])
        l = rounded_feet(raw['length_feet'], raw['length_inches'])
        w && l ? "#{w}x#{l}" : nil
      end

      def rounded_feet(feet, inches)
        f = feet.to_i
        return nil unless f.positive?

        f + (inches.to_i >= 6 ? 1 : 0)
      end

      # photos / line_drawings arrive as JSON-encoded STRINGS inside the record,
      # so they need a second parse.
      def build_images(raw)
        seen = {}

        decode_media(raw['photos']).each do |img|
          url = img['url'].to_s
          next if url.blank? || seen.key?(url)

          seen[url] = { 'source_url' => url, 'local_url' => nil,
                        'alt' => img['alt'] || img['imageAlt'], 'is_floorplan' => false }
        end

        decode_media(raw['line_drawings']).each do |img|
          url = img['url'].to_s
          next if url.blank?

          seen[url] = { 'source_url' => url, 'local_url' => nil,
                        'alt' => img['alt'] || img['imageAlt'], 'is_floorplan' => true }
        end

        seen.values
      end

      def decode_media(value)
        return value.map { |v| v.is_a?(Hash) ? v : {} } if value.is_a?(Array)
        return [] if value.blank?

        parsed = JSON.parse(value.to_s)
        parsed.is_a?(Array) ? parsed.select { |v| v.is_a?(Hash) } : []
      rescue JSON::ParserError
        []
      end

      def tour_for(raw)
        tour = raw['3d_tour'].to_s
        tour.match?(TOUR_RE) ? tour : nil
      end

      # Not a TRACKED_FIELD — additive detail only, and only what the record states.
      def features_for(raw)
        items = []
        items << raw['sections'] if raw['sections'].present?
        items << raw['building_method'] if raw['building_method'].present?
        Array(raw['floorplan_availability']).each { |a| items << a if a.present? }

        items.compact.uniq.any? ? { 'Home details' => items.compact.uniq } : {}
      end

      def raw_extras(raw)
        {
          'brand_name'   => raw['brand_name'],
          'series'       => raw['series'],
          'availability' => Array(raw['floorplan_availability']),
          # Cavco marks which retailers physically have this model on the lot.
          'in_stock'     => Array(raw['floorplan_retailers_in_stock']).include?(retailer_id),
          'model_number' => raw['model_number'],
          'plant_id'     => Array(raw['plant_location_id']).first,
          'source'       => 'cavco'
        }.compact
      end

      def absolute(path)
        return nil if path.blank?
        return path if path.to_s.start_with?('http')

        "#{SITE_ROOT}#{path}"
      end

      def positive_int(value)
        int = value.to_i
        int.positive? ? int : nil
      end

      def decimal(value)
        f = value.to_f
        return nil unless f.positive?

        (f % 1).zero? ? f.to_i : f
      end
    end
  end
end
