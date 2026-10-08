# frozen_string_literal: true

module Truebuild
  # Which TrueBuild model a home on the lot is. A home from a feed carries
  # the model number ("1440 H11065"); one entered by hand or found by a site
  # scan carries it inside a name ("Aspire Dap1676 H32222"), or only a name
  # and a length ("56' Bay Port"), matched on the plan name, the length, and
  # HUD or modular from the home's type.
  #
  # Only a model number is sure enough to link on its own (#confident); a
  # name is a suggestion for the dealer to accept.
  class HomeMatcher
    # Shorter numbers ("1676") turn up inside sizes and stock numbers.
    MIN_NUMBER = 8

    def priced_ids
      @priced_ids ||= CatalogVariantPrice.where(catalog_price_book_id: CatalogPriceBook.published.select(:id))
                                         .distinct.pluck(:catalog_plan_variant_id).to_set
    end

    def priced?(variant_id) = priced_ids.include?(variant_id)

    def variants
      @variants ||= CatalogPlanVariant.active.where(id: priced_ids.to_a).includes(:catalog_plan).to_a
    end

    # The model this home surely is, or nil: one priced model whose number is
    # the home's model text or sits inside it, with the size agreeing where
    # the home records one.
    def confident(vehicle)
      found = by_number(vehicle).select { |v| fits?(vehicle, v) }
      found.one? ? found.first : nil
    end

    # Up to three likely models, best first, with why.
    def suggest(vehicle)
      numbered = by_number(vehicle)
      return numbered.first(3).map { |v| variant_json(v).merge(reason: 'Same model number') } if numbered.any?

      text = vehicle.model.to_s
      named = variants.select { |v| (name = v.catalog_plan&.name.to_s.downcase).length >= 3 && text.downcase.include?(name) }
      length = text[/(\d{2})\s*['’]/, 1]&.to_i || vehicle.try(:length).to_i
      sized = named.select { |v| v.length_ft.to_i == length }
      sized = sized.select { |v| v.building_code == building_code(vehicle) }
      list = sized.any? ? sized.map { |v| [v, "Same name and #{length}' long"] } : named.map { |v| [v, 'Same name'] }
      list.first(3).map { |v, why| variant_json(v).merge(reason: why) }
    end

    # Could a published book cover this home at all? New homes only (a used
    # home sells as it stands), from a builder or plant some book prices.
    # A home that cannot be covered gets no model picker.
    def coverable?(vehicle)
      return true if vehicle.catalog_plan_variant_id
      return false if vehicle.condition.to_s.downcase == 'used'

      words = vehicle.make.to_s.downcase.scan(/[a-z]{3,}/) - %w[homes home the]
      words.any? { |w| covered_words.include?(w) }
    end

    # Links every unlinked new home without a Champion id that surely is a
    # priced model: the one-time sweep for homes saved before #confident
    # existed. Returns [vehicle id, model number] pairs; dry_run links none.
    def link_all(vehicles, dry_run: false)
      vehicles.where(catalog_plan_variant_id: nil, champion_model_id: [nil, ''])
              .where.not(condition: 'used').where("model ~ '[0-9]{4}'").find_each.filter_map do |vehicle|
        variant = confident(vehicle) or next
        vehicle.update_columns(catalog_plan_variant_id: variant.id) unless dry_run
        [vehicle.id, variant.model_number]
      end
    end

    def variant_json(v)
      plan = v.catalog_plan
      { variant_id: v.id, name: [plan&.series, plan&.name].compact.join(' '), model_number: v.model_number,
        size: (v.width_ft && v.length_ft ? "#{v.width_ft}' x #{v.length_ft}'" : nil), building_code: v.building_code }
    end

    private

    def by_number(vehicle)
      text = vehicle.model.to_s.upcase.gsub(/[^A-Z0-9]/, '')
      return [] if text.length < MIN_NUMBER

      found = variants.select { |v| v.model_number.to_s.length >= MIN_NUMBER && text.include?(v.model_number) }
      # A HUD and a modular build can share a number; the home says which.
      by_code = found.select { |v| v.building_code == building_code(vehicle) }
      by_code.any? ? by_code : found
    end

    # A suggestion survives a size that disagrees (a recorded length often
    # includes the hitch); a link made without the dealer does not.
    def fits?(vehicle, variant)
      [[vehicle.try(:width), variant.width_ft], [vehicle.try(:length), variant.length_ft]].all? do |home, model|
        home.to_i.zero? || model.to_i.zero? || home.to_i == model.to_i
      end
    end

    def building_code(vehicle)
      vehicle.try(:home_type).to_s.match?(/modular/i) ? 'MOD' : 'HUD'
    end

    # Words naming a builder or plant that a published book prices:
    # "champion" from Champion Homes, "dutch" from the Topeka, Dutch Housing plant.
    def covered_words
      @covered_words ||= begin
        books = CatalogPriceBook.published.includes(:manufacturer, :factory)
        plants = Factory.where(id: CatalogPlan.where(id: variants.map(&:catalog_plan_id)).select(:factory_id))
        names = books.flat_map { |b| [b.manufacturer&.name, b.factory&.name] } + plants.pluck(:name)
        names.compact.flat_map { |n| n.downcase.scan(/[a-z]{3,}/) }.to_set - %w[homes home the housing]
      end
    end
  end
end
