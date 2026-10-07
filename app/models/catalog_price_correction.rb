# frozen_string_literal: true

# One field of a published price book a platform admin corrected: who, when,
# the old and new value and why. Written by Truebuild::PriceCorrector.
class CatalogPriceCorrection < ApplicationRecord
  belongs_to :price_book, class_name: 'CatalogPriceBook', foreign_key: :catalog_price_book_id
  belongs_to :corrected_by, class_name: 'User', optional: true
  belongs_to :request, class_name: 'CatalogPriceRequest', foreign_key: :catalog_price_request_id, optional: true

  validates :target_type, inclusion: { in: %w[CatalogVariantPrice CatalogOptionPrice] }
  validates :field, presence: true
end
