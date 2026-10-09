# frozen_string_literal: true

# A dealer's terms, company-wide (no manufacturer) or for one manufacturer.
# Factory net prices and freight can differ by dealer, so this is where a
# program discount and freight from the plant live.
class DealerCatalogTerm < ApplicationRecord
  PRICE_UPDATE_POLICIES = %w[review auto_unlocked auto_all].freeze
  PRICE_DISPLAYS = %w[full starting_at monthly hidden].freeze
  BUYER_VIEWS = Truebuild::BuyerView::MODES

  belongs_to :company
  belongs_to :manufacturer, optional: true

  validates :manufacturer_id, uniqueness: { scope: :company_id }
  validates :price_update_policy, inclusion: { in: PRICE_UPDATE_POLICIES }
  validates :price_display, inclusion: { in: PRICE_DISPLAYS }
  validates :buyer_view, inclusion: { in: BUYER_VIEWS }
  validates :program_discount_pct, numericality: { greater_than_or_equal_to: 0, less_than: 100 }
  validates :margin_floor_pct, numericality: { greater_than_or_equal_to: 0, less_than: 100 }, allow_nil: true
  validates :freight_per_mile, :freight_flat, :freight_permit_per_section, :freight_escort_per_mile, :freight_minimum,
            :freight_markup_pct, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :sale_discount_pct, :dealer_savings_pct, :preferred_payment_pct,
            numericality: { greater_than_or_equal_to: 0, less_than: 100 }, allow_nil: true
  validates :freight_escort_width_ft, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :round_retail_to, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :freight_miles, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true

  # Settled once per dealer: what buyers see, how new books arrive, margin
  # floor, rounding. Set per manufacturer: program discount and the buyer
  # discounts a deal sheet starts from.
  COMPANY_WIDE = %i[price_update_policy price_display margin_floor_pct round_retail_to
                    buyer_view buyer_featured_option_ids buyer_hidden_option_ids buyer_hidden_groups
                    factory_po_hide_prices website_designer].freeze
  PER_MANUFACTURER = %i[program_discount_pct sale_discount_pct dealer_savings_pct preferred_payment_pct].freeze
  # The dealer's hauler, so set once for the company; a manufacturer row can
  # still override (a plant that ships its own homes).
  #   freight_per_mile            per mile, per section hauled
  #   freight_flat                per home (paperwork, pilot car minimums)
  #   freight_permit_per_section  state oversize permits, per section
  #   freight_escort_per_mile     escort car, per mile, per section at or over
  #   freight_escort_width_ft     ...this section width
  #   freight_minimum             the least a delivery costs
  #   freight_markup_pct          what the buyer pays over the hauler's cost
  #   freight_miles               miles when the homesite is not known yet
  FREIGHT = %i[freight_per_mile freight_flat freight_permit_per_section freight_escort_per_mile freight_escort_width_ft
               freight_minimum freight_markup_pct freight_miles].freeze
  # Used on the deal sheet until the dealer sets their own, and always shown
  # as assumed. Typical Midwest single-wide/double-wide haul rates, 2026.
  FREIGHT_ASSUMPTIONS = {
    freight_per_mile: 4.50, freight_flat: 0, freight_permit_per_section: 150, freight_escort_per_mile: 1.75,
    freight_escort_width_ft: 16, freight_minimum: 1_000, freight_markup_pct: 20, freight_miles: 150
  }.freeze

  # The terms that apply to one manufacturer's homes: company-wide settings
  # from the company row, discount and freight from the manufacturer row.
  # Unsaved; for reading only.
  def self.effective(company, manufacturer_id)
    rows = company.dealer_catalog_terms.where(manufacturer_id: [manufacturer_id, nil]).to_a
    base = rows.find { |t| t.manufacturer_id.nil? }
    specific = rows.find { |t| t.manufacturer_id == manufacturer_id && manufacturer_id }
    merged = company.dealer_catalog_terms.new(manufacturer_id: manufacturer_id)
    COMPANY_WIDE.each { |f| merged[f] = base[f] if base }
    PER_MANUFACTURER.each { |f| merged[f] = specific[f] if specific }
    FREIGHT.each { |f| merged[f] = specific&.[](f).nil? ? base&.[](f) : specific[f] }
    merged
  end

  # Has the dealer set any freight rate? Until then the deal sheet assumes.
  def freight_set? = FREIGHT.any? { |f| !self[f].nil? }

  # A freight setting, or the assumption when the dealer has not set it.
  # => [value, assumed?]
  def freight_value(field)
    self[field].nil? ? [FREIGHT_ASSUMPTIONS.fetch(field), true] : [self[field], false]
  end

  # The manufacturer row if there is one, else the company default, else a new
  # unsaved default so callers never branch on nil.
  def self.for(company, manufacturer_id)
    rows = company.dealer_catalog_terms.where(manufacturer_id: [manufacturer_id, nil]).to_a
    rows.find { |t| t.manufacturer_id == manufacturer_id } ||
      rows.find { |t| t.manufacturer_id.nil? } ||
      company.dealer_catalog_terms.new
  end
end
