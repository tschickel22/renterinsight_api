# frozen_string_literal: true

module Catalog
  module PriceBooks
    # Reads a price book file already in our own structured form (JSON), with
    # no model reading it: a factory's catalog exported from another system,
    # or kept up to date by a dealer with the factory's blessing. Each home,
    # option and color becomes an import item, so the book is reconciled,
    # reviewed and published like any other.
    #
    #   { "format": "catalog.v1", "partial": true, "source": "...",
    #     "homes":   [{ "model_number", "model_name", "series", "plant", "width_ft", "length_ft",
    #                   "beds", "baths", "net_base_price", "required_adders": [] }],
    #     "options": [{ "section", "description", "dealer_cost", "suggested_retail", "is_standard",
    #                   "tab", "applies_to": {}, "notes" }],
    #     "colors":  [{ "group", "name", "tab" }] }
    #
    # "partial": the file covers part of the plant (one series): homes it does
    # not list are not proposed for removal.
    class StructuredExtractor
      FORMAT = 'catalog.v1'

      def self.structured?(name, bytes)
        File.extname(name.to_s).downcase == '.json' && JSON.parse(bytes)['format'] == FORMAT
      rescue JSON::ParserError
        false
      end

      def initialize(doc, bytes, sink)
        @doc = doc
        @book = doc.price_book
        @sink = sink
        @data = JSON.parse(bytes)
      end

      def call
        raise ExtractionError, "Not a #{FORMAT} catalog file" unless @data['format'] == FORMAT

        homes = Array(@data['homes']).each { |h| home(h) }
        options = Array(@data['options']).each { |o| option(o) }
        colors = Array(@data['colors']).each { |c| color(c) }
        @doc.update!(metadata: @doc.metadata.merge('structured' => true, 'partial' => @data['partial'] == true,
                                                   'source' => @data['source'], 'homes' => homes.size,
                                                   'options' => options.size, 'colors' => colors.size))
      end

      private

      def ref(kind, index) = { 'document_id' => @doc.id, 'structured' => kind, 'index' => index }

      # A model the catalog already has keeps its plan and series, so the
      # file's own spelling ("PEAK REVERSE AISLE") does not start a new plan.
      def home(h)
        number = Catalog::ModelNumber.normalize(h['model_number'].to_s)
        existing = CatalogPlanVariant.includes(:catalog_plan).where(manufacturer_id: @book.manufacturer_id, model_number: number).first
        payload = {
          'model_number' => number, 'model_number_as_printed' => h['model_number'], 'model_name' => h['model_name'],
          'series' => h['series'], 'plant' => h['plant'], 'width_ft' => h['width_ft'], 'length_ft' => h['length_ft'],
          'beds' => h['beds'], 'baths' => h['baths'], 'home_type' => h['home_type'],
          'building_code' => h['building_code'] || Catalog::ModelNumber.parse(number).building_code,
          'net_base_price' => h['net_base_price'], 'required_adders' => Array(h['required_adders']),
          'total_base_price' => h['total_base_price']
        }
        if existing
          payload['plan_series'] = existing.series
          payload['plan_name'] = existing.catalog_plan&.name
        elsif (series = known_series(h['series']))
          # A new model joins the series its plant already uses ("Prime" is Prime Of Indiana).
          payload['plan_series'] = series
        end
        flags = []
        flags << 'price_missing' unless h['net_base_price'].to_f.positive?
        @sink.item(document: @doc, item_type: 'variant_price', payload: payload.compact, source_ref: ref('home', h['model_number']), flags: flags)
      end

      # The plant's existing series whose name contains the file's ("Prime").
      def known_series(name)
        words = name.to_s.downcase.split - %w[champion of the homes]
        return nil if words.empty?

        @plant_series ||= CatalogPlan.where(manufacturer_id: @book.manufacturer_id, factory_id: @book.factory_id).distinct.pluck(:series).compact
        @plant_series.find { |s| (words - s.downcase.split).empty? }
      end

      def option(o)
        flags = []
        flags << 'price_missing' if o['dealer_cost'].nil? && o['suggested_retail'].nil? && o['is_standard'] != true
        @sink.item(document: @doc, item_type: 'option_price', source_ref: ref('option', o['description']), flags: flags,
                   payload: { 'tab' => o['tab'], 'section' => o['section'], 'description' => o['description'],
                              'dealer_cost' => o['dealer_cost'], 'suggested_retail' => o['suggested_retail'],
                              'is_standard' => o['is_standard'] == true, 'applies_to' => (o['applies_to'] || {}).compact,
                              'in_place_of' => o['in_place_of'], 'package_items' => Array(o['package_items']),
                              'notes' => o['notes'] }.compact)
      end

      def color(c)
        @sink.item(document: @doc, item_type: 'option', source_ref: ref('color', "#{c['group']}: #{c['name']}"), flags: [],
                   payload: { 'kind' => 'color', 'tab' => c['tab'], 'group' => c['group'], 'name' => c['name'] }.compact)
      end
    end
  end
end
