# frozen_string_literal: true

module Catalog
  module PriceBooks
    # Which plant builds the homes in a file or tab. A factory package can
    # cover more than one plant: Champion's Topeka package carries Prime,
    # built at Decatur, in its own price list and a "Prime - Decatur factory"
    # tab. The plant is a label on the plans; which book prices a home is
    # decided by the price row (Truebuild::BookResolver), so labelling a plan
    # never leaves it unpriced.
    module Plants
      module_function

      # "Prime - Decatur factory", "Decatur Plant", "Built at Decatur".
      NAMED = /\b([A-Z][A-Za-z.' ]{2,30}?)\s+(?:factory|plant)\b/i

      # The plant a tab or file names, matched against the manufacturer's
      # plants by name or city; a plant named plainly and not yet known is
      # added, as the admin's plant list does.
      def detect(text, manufacturer)
        return nil if text.blank?

        known = manufacturer.factories.to_a
        found = known.find do |f|
          [f.name, f.city].compact.flat_map { |n| n.split(/[,\s]+/) }.reject { |w| w.size < 4 }
                          .any? { |w| text.match?(/\b#{Regexp.escape(w)}\b/i) }
        end
        return found if found

        name = text[NAMED, 1]&.split(/\s+-\s+/)&.last&.strip
        return nil if name.blank? || name.match?(/\A(the|our|this|each|every)\z/i)

        manufacturer.factories.find_or_create_by!(code: name.parameterize.upcase.first(20)) { |f| f.name = name.titleize }
      end

      # The plant for a price row: the file's plant when the admin set one,
      # else the book's. Series named on a plant's tab are relabelled after
      # publishing (label_series).
      def for_item(item, book)
        item.document&.metadata&.dig('plant_id') || book.factory_id
      end

      # Order form tabs that name a plant, by tab: an admin's choice, else detected.
      def tab_plants(doc, manufacturer)
        chosen = doc.metadata['tab_plants'] || {}
        Array(doc.metadata['tab_list']).each_with_object({}) do |t, out|
          name = t['name']
          id = chosen[name] || detect(name, manufacturer)&.id
          out[name] = id if id
        end
      end

      # A tab that names a plant ("Prime - Decatur factory") says where that
      # series is built: label its plans with it, including plans priced from
      # a separate price list. Returns { series => factory_id } applied.
      def label_series(book)
        series_list = CatalogPlan.where(manufacturer_id: book.manufacturer_id).distinct.pluck(:series)
        applied = {}
        book.documents.where(kind: 'order_form').find_each do |doc|
          tab_plants(doc, book.manufacturer).each do |tab, factory_id|
            next if factory_id == book.factory_id

            series = Applicability.series_for(tab, series_list)
            next unless series && series_list.include?(series)

            CatalogPlan.where(manufacturer_id: book.manufacturer_id, series: series).update_all(factory_id: factory_id)
            applied[series] = factory_id
          end
        end
        applied
      end
    end
  end
end
