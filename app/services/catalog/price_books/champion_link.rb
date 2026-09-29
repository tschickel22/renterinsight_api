# frozen_string_literal: true

module Catalog
  module PriceBooks
    # Links price book rows to the models on Champion's public site, which is
    # where Champion IMS inventory gets its ids. The site never prints factory
    # model numbers as text, but its image filenames carry them
    # ("Aspire 3272H32186 Living Room 1"). Found 2026-09-29: 41 of 43 Dutch
    # Housing models linked this way.
    #
    # Champion's own images are sometimes filed under the wrong model (Easton's
    # photos carry Belvidere's number), so a link is only made when the names
    # agree too; a disagreement is flagged for the admin instead.
    class ChampionLink
      ENDPOINT = 'https://www.championhomes.com/content/championhomes/us/en/find-manufactured-modular-home/' \
                 'jcr:content/root/container/container/container/homecardlist.find-a-home.json'
      IMAGE_MODEL = /(\d{4}[HM]\d{2}[0-9A-Z]{3})/i

      def initialize(book, brand_slug:, location:, fetcher: nil)
        @book = book
        @brand_slug = brand_slug
        @location = location
        @fetcher = fetcher || method(:fetch)
      end

      # @return [Hash] counts of linked, name conflicts, and site models with no row
      def call
        models = @fetcher.call
        by_number = {}
        models.each do |m|
          Array(m['images']).flat_map { |img| img.values_at('path', 'alt', 'assetPath') }.compact.join(' ')
                            .scan(IMAGE_MODEL).flatten.map { |n| Catalog::ModelNumber.normalize(n) }.uniq
                            .each { |n| (by_number[n] ||= []) << m }
        end

        linked = conflicts = 0
        matched_ids = Set.new
        @book.import_items.where(item_type: 'variant_price').where("change_type IS DISTINCT FROM 'removed'").find_each do |item|
          p = item.payload
          mn = Catalog::ModelNumber.parse(p['model_number'])
          # The HUD and modular builds share a plan; the site may show either code.
          candidates = (Array(by_number[mn.normalized]) + Array(by_number[mn.sibling_code])).uniq
          site = candidates.find { |m| names_agree?(m['name'], p['plan_name']) }
          if site
            matched_ids << site['id']
            item.update!(payload: p.merge('external' => { 'champion_model_id' => site['id'], 'champion_slug' => site['slug'],
                                                          'champion_name' => site['name'] }))
            linked += 1
          elsif candidates.any?
            item.update!(flags: (item.flags + ['champion_name_conflict']).uniq,
                         payload: p.merge('external_candidates' => candidates.map { |m| m.slice('id', 'slug', 'name') }))
            conflicts += 1
          end
        end

        unmatched = models.reject { |m| matched_ids.include?(m['id']) }.map { |m| m.slice('id', 'slug', 'name') }
        result = { 'site_models' => models.size, 'linked' => linked, 'name_conflicts' => conflicts,
                   'site_models_without_row' => unmatched.first(50) }
        @book.update!(metadata: @book.metadata.merge('champion_link' => result.merge('brand_slug' => @brand_slug, 'location' => @location)))
        result
      end

      private

      # "Aspire Belvidere" and "Belvidere"; "Aspire 089" and "Aspire 089".
      def names_agree?(site_name, plan_name)
        a = site_name.to_s.downcase.split - %w[aspire genesis prime the]
        b = plan_name.to_s.downcase.split - %w[aspire genesis prime the]
        a.any? && b.any? && (a & b).any?
      end

      def fetch
        uri = URI(ENDPOINT)
        uri.query = URI.encode_www_form('Radius' => 500, 'BrandSlug' => @brand_slug, 'Location' => @location,
                                        'pagination-limit' => 500, 'pagination-page' => 1)
        res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 60) do |http|
          http.request(Net::HTTP::Get.new(uri, 'User-Agent' => 'Mozilla/5.0 (DealerTide catalog)', 'Accept' => 'application/json'))
        end
        raise ExtractionError, "Champion's site answered #{res.code}" unless res.is_a?(Net::HTTPSuccess)

        Array(JSON.parse(res.body)['data'])
      end
    end
  end
end
