# frozen_string_literal: true

module Catalog
  module PriceBooks
    # After extraction: match each item to the live catalog and compare it
    # with the book currently published for this plant, so review starts from
    # what changed. Rows that vanished from the new book come back as
    # "removed" items for the admin to confirm.
    class Reconciler
      def initialize(book)
        @book = book
        @current = CatalogPriceBook.current_for(manufacturer_id: book.manufacturer_id, factory_id: book.factory_id)
        @current = nil if @current&.id == book.id
      end

      def call
        variant_prices = @book.import_items.where(item_type: 'variant_price', change_type: [nil, 'new', 'changed', 'unchanged'])
        seen = []
        variant_prices.find_each do |item|
          p = item.payload
          seen << p['model_number']
          series = Keys.series(p['series'], p['plant'])
          p = p.merge('plan_series' => p['plan_series'] || series,
                      'plan_name' => p['plan_name'] || Keys.plan_name(p['model_name'], series, p['model_number']))
          variant = CatalogPlanVariant.find_by(manufacturer_id: @book.manufacturer_id, series: p['plan_series'],
                                               model_number: p['model_number'])
          prev = variant && @current&.variant_prices&.find_by(catalog_plan_variant_id: variant.id)
          change, previous = compare(prev && { 'net_base_price' => prev.net_base_price.to_f }, 'net_base_price' => p['net_base_price'].to_f)
          item.update!(payload: p, matched: variant, change_type: change, previous_values: previous)
        end

        option_prices = @book.import_items.where(item_type: 'option_price')
        option_prices.find_each do |item|
          p = item.payload
          applies = p['applies_to'] || {}
          applies = applies.merge('section_type' => Keys.section_type_from_tab(p['tab'])) if applies['section_type'].blank? || applies['section_type'] == 'any'
          p = p.merge('applies_to' => applies.compact, 'option_key' => Keys.option(p['section'], p['description']))
          option = CatalogOption.find_by(manufacturer_id: @book.manufacturer_id, key: p['option_key'])
          prev = option && @current&.option_prices&.where(catalog_option_id: option.id)&.find { |op| same_applicability?(op, applies) }
          change, previous = compare(prev && { 'dealer_cost' => prev.dealer_cost.to_f }, 'dealer_cost' => p['dealer_cost'].to_f)
          item.update!(payload: p, matched: option, change_type: change, previous_values: previous)
        end

        add_removed(seen) if @current
        @book.update!(metadata: @book.metadata.merge('summary' => summary, 'compared_with' => @current&.id))
      end

      private

      def compare(previous, current)
        return ['new', nil] if previous.nil?

        changed = current.any? { |k, v| (previous[k].to_f - v.to_f).abs > 0.005 }
        [changed ? 'changed' : 'unchanged', previous]
      end

      def same_applicability?(price, applies)
        price.section_type == applies['section_type'] &&
          price.min_length_ft == applies['box_length_min_ft'] && price.max_length_ft == applies['box_length_max_ft'] &&
          price.construction == applies['construction'].presence&.then { |c| c == 'any' ? nil : c }
      end

      def add_removed(seen)
        @current.variant_prices.includes(:variant).find_each do |vp|
          next if seen.include?(vp.variant.model_number)
          next if @book.import_items.where(item_type: 'variant_price', change_type: 'removed', matched: vp.variant).exists?

          @book.import_items.create!(item_type: 'variant_price', change_type: 'removed', matched: vp.variant,
                                     payload: { 'model_number' => vp.variant.model_number, 'net_base_price' => vp.net_base_price.to_f },
                                     previous_values: { 'net_base_price' => vp.net_base_price.to_f },
                                     flags: ['missing_from_new_book'])
        end
      end

      def summary
        items = @book.import_items
        {
          'by_type' => items.group(:item_type).count,
          'by_change' => items.group(:change_type).count.transform_keys { |k| k || 'n/a' },
          'flagged' => items.flagged.count,
          'documents_failed' => @book.documents.where(extraction_status: 'failed').count
        }
      end
    end
  end
end
