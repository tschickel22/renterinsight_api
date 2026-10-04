# frozen_string_literal: true

module Catalog
  module PriceBooks
    # Where a price book can be matched: the homes we already load, and
    # Champion's public brand catalogs.
    module LinkSources
      CHAMPION_ENDPOINT = 'https://www.championhomes.com/content/championhomes/us/en/find-manufactured-modular-home/' \
                          'jcr:content/root/container/container/container/homecardlist.find-a-home.json'
      CHAMPION_FILTERS = 'https://www.championhomes.com/content/championhomes/us/en/find-manufactured-modular-home/' \
                         'jcr:content/root/container/container/findahome.filters.json'

      module_function

      # Homes already in inventory, per feed: Champion IMS per dealer (each
      # dealer has one feed) and each catalog source.
      def loaded
        ims = Vehicle.where(source: 'champion_ims').group(:company_id).count
        companies = Company.where(id: ims.keys).pluck(:id, :name).to_h
        navision = ChampionImsRetailer.where(company_id: ims.keys).pluck(:company_id, :retailer_navision_id)
                                      .group_by(&:first).transform_values { |v| v.map(&:last) }
        brands = Vehicle.where(source: 'champion_ims').group(:company_id, :champion_brand_name).count
                        .each_with_object(Hash.new { |h, k| h[k] = [] }) { |((cid, brand), _), h| h[cid] << brand if brand }

        ims_rows = ims.map do |cid, n|
          { key: "ims:#{cid}", homes: n,
            label: "Champion IMS feed: #{companies[cid] || "company #{cid}"} (#{Array(navision[cid]).join(', ').presence || 'retailer'})",
            detail: brands[cid].uniq.sort.join(', ') }
        end

        catalog = Vehicle.where(source: 'catalog_import').where.not(catalog_source_id: nil).group(:catalog_source_id).count
        names = CatalogSource.where(id: catalog.keys).pluck(:id, :name).to_h
        catalog_rows = catalog.map { |sid, n| { key: "source:#{sid}", homes: n, label: "Catalog source: #{names[sid] || sid}", detail: nil } }

        (ims_rows + catalog_rows).sort_by { |r| -r[:homes] }
      end

      # Models for a loaded source, grouped so one model stocked by several
      # dealers links every one of those homes.
      def loaded_models(key)
        kind, id = key.to_s.split(':', 2)
        scope =
          case kind
          when 'ims' then Vehicle.where(source: 'champion_ims', company_id: id)
          when 'source' then Vehicle.where(source: 'catalog_import', catalog_source_id: id)
          else raise ExtractionError, 'Unknown catalog source'
          end

        scope.select(:id, :model, :champion_model_id, :images, :champion_images, :champion_raw_payload, :floor_plan_images)
             .group_by { |v| v.champion_model_id.presence || "vehicle-#{v.id}" }
             .map do |gid, vs|
               v = vs.first
               { 'id' => gid, 'name' => v.model, 'slug' => nil,
                 'champion_model_id' => v.champion_model_id.presence,
                 'vehicle_ids' => vs.map(&:id),
                 'text' => [v.images, v.champion_images, v.champion_raw_payload&.dig('images'), v.floor_plan_images].to_json }
             end
      end

      def champion_models(brand_slug:, location:)
        uri = URI(CHAMPION_ENDPOINT)
        uri.query = URI.encode_www_form('Radius' => 500, 'BrandSlug' => brand_slug, 'Location' => location,
                                        'pagination-limit' => 500, 'pagination-page' => 1)
        data = Array(get_json(uri)['data'])
        data.map do |m|
          { 'id' => m['id'], 'name' => m['name'], 'slug' => m['slug'], 'champion_model_id' => m['id'],
            'text' => Array(m['images']).flat_map { |img| img.values_at('path', 'alt', 'assetPath') }.compact.join(' ') }
        end
      end

      # Champion's own brand list, so nobody types a slug.
      def champion_brands
        Rails.cache.fetch('truebuild/champion_brands', expires_in: 1.day) do
          Array(get_json(URI(CHAMPION_FILTERS))['Brands']).map { |b| { slug: b['name'].to_s.parameterize, name: b['name'] } }
        end
      rescue StandardError => e
        Rails.logger.warn("[PriceBooks] Champion brand list unavailable: #{e.message}")
        []
      end

      def get_json(uri)
        res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 60) do |http|
          http.request(Net::HTTP::Get.new(uri, 'User-Agent' => 'Mozilla/5.0 (DealerTide catalog)', 'Accept' => 'application/json'))
        end
        raise ExtractionError, "Champion's site answered #{res.code}" unless res.is_a?(Net::HTTPSuccess)

        JSON.parse(res.body)
      end
    end
  end
end
