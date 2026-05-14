# frozen_string_literal: true

# Generates the Champion Homes disclaimer text for public inventory display.
#
# Champion requires retailers to display an "About Champion Homes" blurb
# when showing inventory sourced from their IMS feed. The boilerplate is
# fixed by Champion; only the retailer-specific sentence varies.
#
# Usage:
#   ChampionDisclaimer.for_company(company)
#   #=> { show: true, heading: "About Champion Homes", body: "...", retailer_sentence: "..." }
#
#   ChampionDisclaimer.for_company(company)
#   #=> { show: false }  # when no champion inventory exists
module ChampionDisclaimer
  # This text is required by Champion — do not modify without their approval.
  BOILERPLATE = <<~TEXT.squish
    Champion Homes is one of the largest publicly traded homebuilders in
    North America, offering buyers A Smarter Way Home™ through high quality
    manufactured homes, modular homes, park models, and accessory dwelling
    units (ADUs). The Family of Champion Homes Brands, a portfolio of 24
    quality-focused brands, is a leader in the offsite-built housing
    industry, building innovative homes for thoughtful buyers who want
    affordability and value in a home of their own. With more than 40
    manufacturing facilities across the United States and Canada, Champion
    manufactures beautiful homes that can be personalized to each
    customer's individual lifestyle.
  TEXT

  RETAILER_TEMPLATE = '%{name}, located in %{location}, is an authorized retailer of Champion\'s products.'

  LEARN_MORE = 'Learn more at championhomes.com'

  class << self
    # Returns disclaimer data for a company, or { show: false } if not applicable.
    #
    # @param company [Company] the tenant company
    # @param vehicle_scope [ActiveRecord::Relation, nil] optional — if provided,
    #   only shows the disclaimer when this scope contains champion-sourced vehicles.
    #   When nil, checks whether the company has ANY champion IMS retailers configured.
    def for_company(company, vehicle_scope: nil)
      # Quick check: does this company even have champion inventory?
      retailers = company.champion_ims_retailers.active rescue nil
      return { show: false } if retailers.blank? || retailers.none?

      # If a vehicle scope is provided, only show when results actually contain champion vehicles
      if vehicle_scope
        has_champion = vehicle_scope.where(source: 'champion_ims').exists?
        return { show: false } unless has_champion
      end

      # Build the retailer sentence from the first active retailer
      # (most dealers have one; if multiple, use the first with name data)
      retailer = retailers.find { |r| r.retailer_name.present? } || retailers.first
      retailer_sentence = build_retailer_sentence(retailer)

      {
        show: true,
        heading: 'About Champion Homes',
        body: BOILERPLATE,
        retailer_sentence: retailer_sentence,
        learn_more_url: 'https://www.championhomes.com',
        learn_more_text: LEARN_MORE,
        # Full combined text for simple rendering
        full_text: [BOILERPLATE, retailer_sentence, LEARN_MORE].compact.reject(&:blank?).join(' ')
      }
    end

    private

    def build_retailer_sentence(retailer)
      return nil unless retailer

      # Use custom sentence if the dealer provided one
      return retailer.custom_retailer_sentence if retailer.custom_retailer_sentence.present?

      # Auto-generate from retailer metadata
      name = retailer.retailer_name
      return nil if name.blank?

      location_parts = [retailer.retailer_city, retailer.retailer_state].compact.reject(&:blank?)
      location = location_parts.any? ? location_parts.join(', ') : nil

      if location
        format(RETAILER_TEMPLATE, name: name, location: location)
      else
        "#{name} is an authorized retailer of Champion's products."
      end
    end
  end
end
