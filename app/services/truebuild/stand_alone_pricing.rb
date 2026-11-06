# frozen_string_literal: true

module Truebuild
  # What a home no price book covers starts from: the dealer's All other homes
  # pack and discount, and their All homes markup. The rep sees and can change
  # every figure, so a typed price is never marked up behind their back.
  class StandAlonePricing
    def initialize(company, location: nil)
      @company = company
      @location = location
    end

    def defaults
      terms = DealerCatalogTerm.effective(@company, nil)
      { pack: terms.dealer_pack&.to_f, discount_pct: terms.sale_discount_pct&.to_f, markup: markup }
    end

    # What the sheet takes from an inventory home that has no catalog model.
    # A discount in percent of the home stays a percent; the other kinds become
    # dollars, the difference the inventory record already worked out.
    def self.inventory_figures(vehicle)
      figures = { cost: vehicle.structured_cost&.to_f, pack: vehicle.pack_amount&.to_f,
                  price: (vehicle.msrp.presence || vehicle.sale_price.presence)&.to_f,
                  width_ft: vehicle.width, length_ft: vehicle.length, beds: vehicle.bedrooms, baths: vehicle.bathrooms&.to_f,
                  maker: vehicle.make, model: vehicle.model }
      return figures unless vehicle.special_discount_enabled && vehicle.discounted_price.present?

      if vehicle.discount_type == '% of Home Price'
        figures.merge(discount_pct: vehicle.discount_value.to_f)
      elsif vehicle.msrp.to_f.positive?
        figures.merge(discount_amount: [vehicle.msrp.to_f - vehicle.discounted_price.to_f, 0].max.round(2))
      else
        figures
      end
    end

    private

    # The rule as something to multiply by; nil when it is not one (a flat or
    # manual rule says nothing about a home no one has priced). A sliding scale
    # depends on the home's cost, so it comes back as its settings and the
    # screen works the price out from cost + pack, as the engine does.
    def markup
      rule = @company.dealer_markup_rules.active.where(scope_type: 'all', applies_to: %w[base base_and_options]).to_a
                     .select { |r| r.location_id.nil? || r.location_id == @location&.id }
                     .max_by(&:rank)
      return nil unless rule

      if rule.sliding?
        return { times: nil, type: 'sliding', sliding_multiplier: rule.sliding_multiplier.to_f,
                 sliding_curve: rule.sliding_curve.to_f, minimum_markup: rule.minimum_markup.to_f }
      end

      times = case rule.markup_type
              when 'multiplier' then rule.value.to_f
              when 'percent' then (1 + (rule.value.to_d / 100)).to_f
              end
      times && { times: times.round(4), type: rule.markup_type, value: rule.value.to_f }
    end
  end
end
