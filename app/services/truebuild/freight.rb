# frozen_string_literal: true

module Truebuild
  # Freight from the plant to the homesite, as a hauler bills it: per mile for
  # each section hauled, an escort car for sections at or over a width, state
  # permits per section, a flat amount per home, never under a minimum. The
  # buyer pays that cost plus the dealer's freight markup.
  #
  # Every rate is the dealer's setting (DealerCatalogTerm::FREIGHT); one the
  # dealer has not set uses the stated assumption and says so.
  class Freight
    # Straight-line miles between zip centers, to road miles.
    ROAD_FACTOR = 1.2

    def self.sections(variant)
      width = variant.width_ft.to_i
      return 1 if width.zero? || width <= 18
      return 2 if width <= 36

      3
    end

    # Road miles from the home's plant to the homesite: the deal's delivery
    # zip, else its location's, else the dealer's. => [miles, how] or nil.
    def self.estimate_miles(variant, deal)
      factory = variant.catalog_plan&.factory
      return nil unless factory

      from = factory.latitude && factory.longitude ? [factory.latitude, factory.longitude] : ZipPoint.call(factory.zip)
      to_zip, where = [[deal.try(:delivery_zip), 'the delivery address'], [deal.try(:location)&.zip_code, 'your location'],
                       [deal.try(:company)&.zip_code, 'your dealership']].find { |z, _| z.present? }
      to = to_zip && ZipPoint.call(to_zip)
      return nil unless from && to

      [(ZipPoint.miles(from, to) * ROAD_FACTOR).round, "#{factory.name} to #{where} (#{to_zip}), estimated"]
    end

    def initialize(terms:, variant:, miles: nil)
      @terms = terms
      @variant = variant
      @miles = miles
    end

    # => { cost:, retail:, detail: { ... } }
    def call
      assumed = []
      rate = lambda do |field|
        value, guess = @terms.freight_value(field)
        assumed << field.to_s.delete_prefix('freight_') if guess
        value.to_d
      end
      miles = @miles || rate.call(:freight_miles).to_i
      sections = self.class.sections(@variant)
      section_width = @variant.width_ft.to_i.positive? ? (@variant.width_ft.to_d / sections) : 0
      escorted = section_width >= rate.call(:freight_escort_width_ft) ? sections : 0

      haul = rate.call(:freight_per_mile) * miles * sections
      escort = rate.call(:freight_escort_per_mile) * miles * escorted
      permits = rate.call(:freight_permit_per_section) * sections
      flat = rate.call(:freight_flat)
      cost = [haul + escort + permits + flat, rate.call(:freight_minimum)].max.round(0)
      retail = (cost * (1 + (rate.call(:freight_markup_pct) / 100))).round(0)
      { cost: cost.to_f, retail: retail.to_f,
        detail: { miles: miles, sections: sections, escorted_sections: escorted, haul: haul.round(2).to_f,
                  escort: escort.round(2).to_f, permits: permits.to_f, flat: flat.to_f, assumed: assumed.uniq } }
    end
  end
end
