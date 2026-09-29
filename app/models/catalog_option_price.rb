# frozen_string_literal: true

# An option's price in one book, for the homes it applies to. The same option
# often has several rows: drywall is priced by box length band, carpet by
# single or multi-section, a package by model.
class CatalogOptionPrice < ApplicationRecord
  SECTION_TYPES = %w[single multi].freeze
  CONSTRUCTIONS = %w[vog drywall partial_drywall].freeze

  belongs_to :price_book, class_name: 'CatalogPriceBook', foreign_key: :catalog_price_book_id, inverse_of: :option_prices
  belongs_to :option, class_name: 'CatalogOption', foreign_key: :catalog_option_id, inverse_of: :prices
  belongs_to :variant, class_name: 'CatalogPlanVariant', foreign_key: :catalog_plan_variant_id, optional: true

  validates :dealer_cost, presence: true, unless: :is_standard?
  validates :section_type, inclusion: { in: SECTION_TYPES }, allow_nil: true
  validates :construction, inclusion: { in: CONSTRUCTIONS }, allow_nil: true
  validates :building_code, inclusion: { in: CatalogPlanVariant::BUILDING_CODES }, allow_nil: true
  validate :length_band_order

  # Does this price row apply to the given variant?
  def applies_to?(variant, construction: nil)
    return variant.id == catalog_plan_variant_id if catalog_plan_variant_id
    return false if building_code && building_code != variant.building_code
    return false if width_ft && width_ft != variant.width_ft
    return false if min_length_ft && variant.length_ft.to_i < min_length_ft
    return false if max_length_ft && variant.length_ft.to_i > max_length_ft
    return false if section_type && section_type != (variant.width_ft.to_i <= 18 ? 'single' : 'multi')
    return false if self.construction && construction && self.construction != construction
    return false if series.present? && series != variant.catalog_plan.series

    true
  end

  private

  def length_band_order
    return unless min_length_ft && max_length_ft && min_length_ft > max_length_ft

    errors.add(:max_length_ft, 'must be at least the minimum length')
  end
end
