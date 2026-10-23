# frozen_string_literal: true

# A dealer's report that a price book has a wrong price, sent from a deal
# sheet line or their price list. A platform admin applies the correction to
# the book (for every dealer), keeps it for that dealer only, or dismisses it,
# and the dealer is told which.
#
# A COST request is also the dealer's own cost (backlog E85): while it is
# open or dealer_only, Truebuild::DealerPrices prices that row at their figure
# for them alone, so they never enter it twice. A newer figure, or going back
# to the factory's, withdraws it. A SURCHARGE request does the same for a
# home's required adders (applied to the book as its total base price).
class CatalogPriceRequest < ApplicationRecord
  STATUSES = %w[open applied dealer_only dismissed withdrawn].freeze
  # Statuses whose figure prices the row for the dealer who sent it.
  OVERRIDING = %w[open dealer_only].freeze
  # What the dealer says is wrong: the price the buyer is charged, the dealer's
  # cost, or a home's surcharge (its required adders).
  FIELDS = %w[price cost surcharge].freeze

  belongs_to :company
  belongs_to :price_book, class_name: 'CatalogPriceBook', foreign_key: :catalog_price_book_id
  belongs_to :deal, optional: true
  belongs_to :requested_by, class_name: 'User', optional: true
  belongs_to :resolved_by, class_name: 'User', optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :field, inclusion: { in: FIELDS }
  validates :target_type, inclusion: { in: %w[CatalogVariantPrice CatalogOptionPrice] }
  validates :label, presence: true
  validate { errors.add(:field, 'surcharge is only on a home') if field == 'surcharge' && target_type != 'CatalogVariantPrice' }

  scope :open, -> { where(status: 'open') }
  scope :overriding, -> { where(field: 'cost', status: OVERRIDING).where.not(suggested_value: nil) }
  scope :overriding_surcharge, -> { where(field: 'surcharge', status: OVERRIDING).where.not(suggested_value: nil) }

  def target = target_type.constantize.find_by(id: target_id)

  # The book column the dealer's field means: a home's base price is its cost
  # (retail comes from the dealer's markup); an option has both.
  def book_field
    return 'total_base_price' if field == 'surcharge'
    return 'net_base_price' if target_type == 'CatalogVariantPrice'

    field == 'price' ? 'suggested_retail' : 'dealer_cost'
  end

  # The book value applying `value` means: a surcharge goes in as the total
  # base price (net base plus surcharge), which the book prices ahead of its adders.
  def book_value_for(value, row = target)
    return value unless field == 'surcharge' && value.present?

    row.net_base_price.to_d + BigDecimal(value.to_s.delete(',$'))
  end
end
