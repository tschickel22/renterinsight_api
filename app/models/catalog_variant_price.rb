# frozen_string_literal: true

# A model's net base price in one price book, plus any adders the factory
# requires (modular conversion, drywall, detectors).
class CatalogVariantPrice < ApplicationRecord
  belongs_to :price_book, class_name: 'CatalogPriceBook', foreign_key: :catalog_price_book_id, inverse_of: :variant_prices
  belongs_to :variant, class_name: 'CatalogPlanVariant', foreign_key: :catalog_plan_variant_id, inverse_of: :variant_prices

  validates :net_base_price, numericality: { greater_than: 0 }
  validates :catalog_plan_variant_id, uniqueness: { scope: :catalog_price_book_id }

  before_validation { self.required_adders = Array(required_adders).map { |a| a.to_h.deep_stringify_keys } }

  # Net base plus required adders; the printed total wins when the sheet has one.
  def base_cost
    total_base_price || (net_base_price + required_adders.sum { |a| a['amount'].to_d })
  end
end
