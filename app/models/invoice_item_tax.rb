# frozen_string_literal: true

# Snapshot of a specific tax code's contribution to one invoice line item.
# Recorded at compute time so historical invoices don't shift if tax rates
# later change. Sum of these rows per invoice item is the item's tax_amount.
class InvoiceItemTax < ApplicationRecord
  belongs_to :invoice_item
  belongs_to :tax_code

  validates :computed_amount, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :computed_rate,   presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :taxable_base,    presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :tax_code_id, uniqueness: { scope: :invoice_item_id }
end
