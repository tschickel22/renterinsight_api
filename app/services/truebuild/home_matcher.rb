# frozen_string_literal: true

module Truebuild
  # Which TrueBuild model a home on the lot is. A home from a feed carries
  # the model number ("1440 H11065"); one entered by hand carries a name and
  # a length ("56' Bay Port"), matched on the plan name, the length, and
  # HUD or modular from the home's type.
  class HomeMatcher
    def priced_ids
      @priced_ids ||= CatalogVariantPrice.where(catalog_price_book_id: CatalogPriceBook.published.select(:id))
                                         .distinct.pluck(:catalog_plan_variant_id).to_set
    end

    def priced?(variant_id) = priced_ids.include?(variant_id)

    def variants
      @variants ||= CatalogPlanVariant.active.where(id: priced_ids.to_a).includes(:catalog_plan).to_a
    end

    # Up to three likely models, best first, with why.
    def suggest(vehicle)
      text = vehicle.model.to_s
      number = text.upcase.gsub(/[^A-Z0-9]/, '')
      exact = variants.select { |v| number.present? && v.model_number == number }
      return exact.first(3).map { |v| variant_json(v).merge(reason: 'Same model number') } if exact.any?

      named = variants.select { |v| (name = v.catalog_plan&.name.to_s.downcase).length >= 3 && text.downcase.include?(name) }
      length = text[/(\d{2})\s*['’]/, 1]&.to_i || vehicle.try(:length).to_i
      sized = named.select { |v| v.length_ft.to_i == length }
      # The same plan comes HUD and modular; the home says which it is.
      code = vehicle.try(:home_type).to_s.match?(/modular/i) ? 'MOD' : 'HUD'
      sized = sized.select { |v| v.building_code == code }
      list = sized.any? ? sized.map { |v| [v, "Same name and #{length}' long"] } : named.map { |v| [v, 'Same name'] }
      list.first(3).map { |v, why| variant_json(v).merge(reason: why) }
    end

    def variant_json(v)
      plan = v.catalog_plan
      { variant_id: v.id, name: [plan&.series, plan&.name].compact.join(' '), model_number: v.model_number,
        size: (v.width_ft && v.length_ft ? "#{v.width_ft}' x #{v.length_ft}'" : nil), building_code: v.building_code }
    end
  end
end
