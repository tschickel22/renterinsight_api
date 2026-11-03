# frozen_string_literal: true

module Truebuild
  # A home no price book has: a used home, or one from a maker not in the
  # catalog. The Deal Sheet hangs off a catalog model, so the dealer's typed
  # home becomes a private one, under a manufacturer that holds only these. It
  # has no prices and no photos, so it never reaches a model list or a buyer,
  # and the sheet takes its price and cost as typed.
  class ManualHome
    MANUFACTURER = 'Not in catalog'

    def self.create!(company:, description:, maker: nil, model: nil, width_ft: nil, length_ft: nil, beds: nil, baths: nil, building_code: nil)
      description = description.to_s.squish
      raise ArgumentError, 'Describe the home' if description.blank?

      manufacturer = Manufacturer.find_or_create_by!(name: MANUFACTURER) { |m| m.industry_type = 'manufactured_home' }
      token = SecureRandom.hex(6)
      series = "dealer-#{company.id}"
      CatalogPlanVariant.transaction do
        plan = CatalogPlan.create!(manufacturer: manufacturer, series: series, name: description, slug: "#{description.parameterize.first(60)}-#{token}",
                                   metadata: { 'manual_home' => true, 'company_id' => company.id })
        CatalogPlanVariant.create!(
          catalog_plan: plan, manufacturer: manufacturer, series: series, model_number: "HAND-#{token.upcase}",
          building_code: CatalogPlanVariant::BUILDING_CODES.include?(building_code) ? building_code : 'HUD',
          width_ft: width_ft.presence, length_ft: length_ft.presence, beds: beds.presence, baths: baths.presence,
          external_ids: { 'manual_home' => true, 'company_id' => company.id, 'maker' => maker.to_s.squish.presence, 'model' => model.to_s.squish.presence }.compact
        )
      end
    end
  end
end
