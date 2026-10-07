# frozen_string_literal: true

# A dealer's report that a price book has a wrong price, sent from a deal
# sheet line. The dealer sets the right figure on the deal meanwhile; a
# platform admin applies the correction to the book (for every dealer) or
# dismisses it, and the dealer is told which.
class CatalogPriceRequest < ApplicationRecord
  STATUSES = %w[open applied dismissed].freeze
  # What the dealer says is wrong: the price the buyer is charged, or the dealer's cost.
  FIELDS = %w[price cost].freeze

  belongs_to :company
  belongs_to :price_book, class_name: 'CatalogPriceBook', foreign_key: :catalog_price_book_id
  belongs_to :deal, optional: true
  belongs_to :requested_by, class_name: 'User', optional: true
  belongs_to :resolved_by, class_name: 'User', optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :field, inclusion: { in: FIELDS }
  validates :target_type, inclusion: { in: %w[CatalogVariantPrice CatalogOptionPrice] }
  validates :label, presence: true

  scope :open, -> { where(status: 'open') }

  def target = target_type.constantize.find_by(id: target_id)

  # The book column the dealer's field means: a home's base price is its cost
  # (retail comes from the dealer's markup); an option has both.
  def book_field
    return 'net_base_price' if target_type == 'CatalogVariantPrice'

    field == 'price' ? 'suggested_retail' : 'dealer_cost'
  end
end
