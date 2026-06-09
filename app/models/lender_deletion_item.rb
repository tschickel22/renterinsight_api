# frozen_string_literal: true

# One line of a lender's DELETION schedule (Max Advance Phase 2) — amounts subtracted
# from the invoice basis per lender rules. Company-scoped child of a Lender. Config only.
#
# `invoice_reference` lets a deletion pull its amount from a vehicle-invoice field at
# calculation time (e.g. 'factory_freight', 'sales_allowance') instead of a fixed amount.
# `single_amount`/`multi_amount` hold section-variant deletions (e.g. wheels/axles
# SW $500 / DW $1000).
class LenderDeletionItem < ApplicationRecord
  belongs_to :lender
  belongs_to :company

  NAMES = %w[
    wheels_axles factory_freight dealer_rebate ac tax_from_invoice hud_fees
    packs advertising trim_out other
  ].freeze

  validates :name, presence: true, inclusion: { in: NAMES }
  validates :amount, :single_amount, :multi_amount, numericality: true, allow_nil: true

  scope :active, -> { where(active: true) }
end
