# frozen_string_literal: true

# A dealer's decision on a published price book when their policy holds new
# books for review.
class DealerPriceBookAdoption < ApplicationRecord
  # superseded: a newer book arrived before the dealer decided on this one.
  STATUSES = %w[pending adopted declined superseded].freeze

  belongs_to :company
  belongs_to :price_book, class_name: 'CatalogPriceBook', foreign_key: :catalog_price_book_id,
                          inverse_of: :dealer_adoptions
  belongs_to :decided_by, class_name: 'User', optional: true
  belongs_to :previous_book, class_name: 'CatalogPriceBook', optional: true

  scope :pending, -> { where(status: 'pending') }

  validates :status, inclusion: { in: STATUSES }
  validates :catalog_price_book_id, uniqueness: { scope: :company_id }
end
