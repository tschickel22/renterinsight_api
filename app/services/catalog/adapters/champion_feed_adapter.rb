# frozen_string_literal: true

module Catalog
  module Adapters
    # Wraps the existing Champion IMS feed (Scrapers::ChampionImsClient) in the
    # adapter interface so Champion appears in the same management / health view
    # as the scraper-based sources. This is a thin facade — the heavy Champion
    # ingestion/tombstoning still lives in Scrapers::ChampionImsSyncService and
    # is unaffected. Here we only normalize feed entries for the unified health
    # dashboard and the "Test" dry-run.
    #
    # config: { "navision_id" => "0551KS", "radius" => 200 }
    class ChampionFeedAdapter < BaseAdapter
      def crawl_delay
        0 # JSON feed; client already spaces PDP fetches internally
      end

      def discover(limit: nil)
        @homes ||= client.fetch_all.each_with_object({}) do |home, acc|
          key = model_id(home)
          acc[key] = home if key.present?
        end
        keys = @homes.keys
        limit ? keys.first(limit) : keys
      end

      def fetch(key)
        (@homes ||= {})[key] || {}
      end

      def parse(raw)
        gallery, floor_plans = partition_images(raw)

        NormalizedHome.new(
          source_key:    model_id(raw),
          source_url:    raw['url'] || raw['detailUrl'],
          model_name:    pick(raw, %w[name title modelName model_name]),
          model_id:      pick(raw, %w[modelNumber model_number sku]),
          series:        pick(raw, %w[series collection brand]),
          property_type: Array(pick(raw, %w[homeType home_type type])).flatten.compact,
          bedrooms:      to_int(pick(raw, %w[bedrooms beds numBedrooms])),
          bathrooms:     to_decimal(pick(raw, %w[bathrooms baths numBathrooms])),
          dimensions:    pick(raw, %w[dimensions size]),
          square_feet:   to_int(pick(raw, %w[squareFeet square_feet sqft])),
          description:   pick(raw, %w[description summary]),
          features:      { 'Features' => Array(pick(raw, %w[features amenities])).flatten.compact },
          images:        (gallery + floor_plans),
          virtual_tour_url: pick(raw, %w[matterportUrl virtualTour]),
          price_quote_url:  nil,
          raw: { 'navision_id' => navision_id }
        )
      end

      private

      def client
        @client ||= Scrapers::ChampionImsClient.new(
          navision_id: navision_id,
          radius: Integer(source.config['radius'] || 200)
        )
      end

      def navision_id
        source.config['navision_id'].presence || source.manufacturer_id
      end

      def model_id(home)
        %w[id modelId model_id uuid].each do |k|
          v = home[k]
          return v.to_s if v.present?
        end
        nil
      end

      def partition_images(home)
        images = Array(home['images'] || home['photos'] || home['media'])
        gallery = []
        floor_plans = []
        images.each do |img|
          url = img.is_a?(Hash) ? (img['url'] || img['src']) : img
          alt = img.is_a?(Hash) ? img['alt'].to_s : ''
          next if url.blank?

          record = { 'source_url' => url, 'local_url' => nil, 'alt' => alt,
                     'is_floorplan' => "#{url} #{alt}".downcase.match?(/floor[\s_-]?plan/) }
          record['is_floorplan'] ? floor_plans << record : gallery << record
        end
        [gallery, floor_plans]
      end

      def pick(home, keys)
        keys.each do |k|
          v = home[k]
          return v if v.present?
        end
        nil
      end

      def to_int(value)
        return nil if value.blank?

        value.to_s.gsub(/[^\d]/, '').presence&.to_i
      end

      def to_decimal(value)
        return nil if value.blank?

        m = value.to_s.match(/\d+(\.\d+)?/)
        m && m[0]
      end
    end
  end
end
