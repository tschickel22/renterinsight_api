# frozen_string_literal: true

module Catalog
  module PriceBooks
    # Links price book rows to catalog models, so homes on dealer lots find
    # their factory prices. Two kinds of source:
    #
    #   loaded:  homes we already pull (a Champion IMS feed, a catalog source).
    #            Links those exact inventory rows.
    #   champion_site:  Champion's full public catalog for one brand. Covers
    #            every model the plant builds, stocked or not; Champion IMS
    #            uses the same model ids, so any dealer's feed links later.
    #
    # Neither prints factory model numbers as text, but image names carry them
    # ("Aspire 3272H32186 Living Room 1"). Champion's own images are sometimes
    # filed under the wrong model (Easton's photos carry Belvidere's number),
    # so a link is only made when the names agree too; a disagreement is
    # flagged for the admin instead.
    class CatalogLink
      MODEL_IN_TEXT = /(\d{4}[HM]\d{2}[0-9A-Z]{3})/i
      NOISE_WORDS = %w[aspire genesis prime the home homes].freeze

      # @param models [Array<Hash>] { 'id', 'name', 'slug', 'text', 'vehicle_ids' }
      def initialize(book, models:, label:)
        @book = book
        @models = models
        @label = label
      end

      def call
        by_number = {}
        @models.each do |m|
          m['text'].to_s.scan(MODEL_IN_TEXT).flatten.map { |n| Catalog::ModelNumber.normalize(n) }.uniq
                   .each { |n| (by_number[n] ||= []) << m }
        end

        linked = conflicts = 0
        matched = Set.new
        rows = @book.import_items.where(item_type: 'variant_price').where("change_type IS DISTINCT FROM 'removed'")
        rows.find_each do |item|
          p = item.payload
          mn = Catalog::ModelNumber.parse(p['model_number'])
          # The HUD and modular builds share a plan; a catalog may show either code.
          candidates = (Array(by_number[mn.normalized]) + Array(by_number[mn.sibling_code])).uniq
          hits = candidates.select { |m| names_agree?(m['name'], p['plan_name'] || p['model_name']) }
          if hits.any?
            hits.each { |m| matched << m['id'] }
            item.update!(payload: p.merge('external' => merge_external(p['external'], hits)),
                         flags: item.flags - ['catalog_name_conflict'])
            linked += 1
          elsif candidates.any?
            item.update!(flags: (item.flags + ['catalog_name_conflict']).uniq,
                         payload: p.merge('external_candidates' => candidates.map { |m| m.slice('id', 'slug', 'name') }))
            conflicts += 1
          end
        end

        unmatched = @models.reject { |m| matched.include?(m['id']) }.map { |m| m.slice('id', 'slug', 'name') }
        result = { 'source' => @label, 'models' => @models.size, 'linked' => linked, 'name_conflicts' => conflicts,
                   'models_without_row' => unmatched.first(50), 'linked_at' => Time.current.iso8601 }
        links = Array(@book.metadata['catalog_links']).reject { |l| l['source'] == @label } + [result]
        @book.update!(metadata: @book.metadata.merge('catalog_links' => links))
        result
      end

      private

      def merge_external(existing, hits)
        ext = (existing || {}).dup
        champion = hits.find { |m| m['champion_model_id'] }
        ext.merge!('champion_model_id' => champion['champion_model_id'], 'champion_slug' => champion['slug'],
                   'champion_name' => champion['name']) if champion
        ids = (Array(ext['vehicle_ids']) + hits.flat_map { |m| Array(m['vehicle_ids']) }).uniq
        ext['vehicle_ids'] = ids if ids.any?
        ext
      end

      # "Aspire Belvidere" and "Belvidere"; "Aspire 089" and "Aspire 089".
      def names_agree?(catalog_name, plan_name)
        a = catalog_name.to_s.downcase.scan(/[a-z0-9]+/) - NOISE_WORDS
        b = plan_name.to_s.downcase.scan(/[a-z0-9]+/) - NOISE_WORDS
        a.any? && b.any? && (a & b).any?
      end
    end
  end
end
