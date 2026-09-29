# frozen_string_literal: true

# One thing extraction proposed (a base price, an option price, a rule, a
# standard feature, a product change), waiting for a platform admin. Nothing
# reaches the live catalog until it is approved and the book is published.
class CatalogImportItem < ApplicationRecord
  ITEM_TYPES = %w[variant_price option option_price rule standard_feature product_change].freeze
  CHANGE_TYPES = %w[new changed unchanged removed].freeze
  REVIEW_STATUSES = %w[pending approved rejected edited].freeze

  belongs_to :price_book, class_name: 'CatalogPriceBook', foreign_key: :catalog_price_book_id, inverse_of: :import_items
  belongs_to :document, class_name: 'CatalogPriceBookDocument', foreign_key: :catalog_price_book_document_id,
                        optional: true, inverse_of: :import_items
  belongs_to :reviewed_by, class_name: 'User', optional: true
  belongs_to :matched, polymorphic: true, optional: true

  validates :item_type, inclusion: { in: ITEM_TYPES }
  validates :change_type, inclusion: { in: CHANGE_TYPES }, allow_nil: true
  validates :review_status, inclusion: { in: REVIEW_STATUSES }

  before_validation :stringify_json

  scope :pending, -> { where(review_status: 'pending') }
  scope :flagged, -> { where("jsonb_array_length(flags) > 0") }

  private

  # Symbol keys break comparisons and the review UI (see CLAUDE.md).
  def stringify_json
    self.payload = payload.deep_stringify_keys if payload.is_a?(Hash)
    self.source_ref = source_ref.deep_stringify_keys if source_ref.is_a?(Hash)
    self.previous_values = previous_values.deep_stringify_keys if previous_values.is_a?(Hash)
    self.flags = Array(flags).map(&:to_s)
  end
end
