# frozen_string_literal: true

# Per-tax-code snapshot for a credit memo line item. Same shape as
# InvoiceItemTax so a credit against a compound-taxed invoice reverses
# the same jurisdictional breakdown.
class CreditMemoItemTax < ApplicationRecord
  belongs_to :credit_memo_item
  belongs_to :tax_code

  validates :computed_amount, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :computed_rate,   presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :taxable_base,    presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :tax_code_id, uniqueness: { scope: :credit_memo_item_id }
end
