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
      # Words that say nothing about which plant: "Meridian Factory" must not
      # match every tab that says "factory", nor "Champion Homes - Topeka"
      # every tab that says "homes".
      GENERIC = %w[factory factories plant plants homes home housing manufactured modular options option base price
                   list series standard standards the and inc llc].freeze

      # create: false (the default) only finds; publishing passes true.
      def detect(text, manufacturer, create: false)
        return nil if text.blank?

        stop = GENERIC + manufacturer.name.to_s.downcase.split(/[^a-z0-9]+/)
        found = manufacturer.factories.to_a.find do |f|
          [f.name, f.city].compact.flat_map { |n| n.downcase.split(/[^a-z0-9]+/) }.uniq
                          .reject { |w| w.size < 4 || stop.include?(w) }
                          .any? { |w| text.match?(/\b#{Regexp.escape(w)}\b/i) }
        end
        return found if found || !create

        name = text[NAMED, 1]&.split(/\s+-\s+/)&.last&.strip
        return nil if name.blank? || name.downcase.split.all? { |w| stop.include?(w) }

        manufacturer.factories.find_or_create_by!(code: name.parameterize.upcase.first(20)) { |f| f.name = name.titleize }
      end

      # The plant for a price row: the file's plant when the admin set one,
      # else the book's. Series named on a plant's tab are relabelled after
      # publishing (label_series).
      def for_item(item, book)
        item.document&.metadata&.dig('plant_id') || book.factory_id
      end

      # Order form tabs that name a plant, by tab: an admin's choice, else detected.
      def tab_plants(doc, manufacturer, create: false)
        chosen = doc.metadata['tab_plants'] || {}
        Array(doc.metadata['tab_list']).each_with_object({}) do |t, out|
          name = t['name']
          id = chosen[name] || detect(name, manufacturer, create: create)&.id
          out[name] = id if id
        end
      end

      # A tab that names a plant ("Prime - Decatur factory") says where that
      # series is built: label its plans with it, including plans priced from
      # a separate price list. Returns { series => factory_id } applied.
      def label_series(book, create: true)
        series_list = CatalogPlan.where(manufacturer_id: book.manufacturer_id).distinct.pluck(:series)
        applied = {}
        book.documents.where(kind: 'order_form').find_each do |doc|
          tab_plants(doc, book.manufacturer, create: create).each do |tab, factory_id|
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
