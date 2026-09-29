# frozen_string_literal: true

# A dealer's terms, company-wide (no manufacturer) or for one manufacturer.
# Factory net prices and freight can differ by dealer, so this is where a
# program discount and freight from the plant live.
class DealerCatalogTerm < ApplicationRecord
  PRICE_UPDATE_POLICIES = %w[review auto_unlocked auto_all].freeze
  PRICE_DISPLAYS = %w[full starting_at monthly hidden].freeze

  belongs_to :company
  belongs_to :manufacturer, optional: true

  validates :manufacturer_id, uniqueness: { scope: :company_id }
  validates :price_update_policy, inclusion: { in: PRICE_UPDATE_POLICIES }
  validates :price_display, inclusion: { in: PRICE_DISPLAYS }
  validates :program_discount_pct, numericality: { greater_than_or_equal_to: 0, less_than: 100 }
  validates :margin_floor_pct, numericality: { greater_than_or_equal_to: 0, less_than: 100 }, allow_nil: true
  validates :freight_per_mile, :freight_flat, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :round_retail_to, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true

  # The manufacturer row if there is one, else the company default, else a new
  # unsaved default so callers never branch on nil.
  def self.for(company, manufacturer_id)
    rows = company.dealer_catalog_terms.where(manufacturer_id: [manufacturer_id, nil]).to_a
    rows.find { |t| t.manufacturer_id == manufacturer_id } ||
      rows.find { |t| t.manufacturer_id.nil? } ||
      company.dealer_catalog_terms.new
  end
end
