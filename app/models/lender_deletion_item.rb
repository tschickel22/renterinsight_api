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

  # Default deletion schedule (21st Mortgage structure — freight/HUD/tax/trim are
  # near-universal MH lender deletions). Seeded onto every new lender so the Max Advance
  # calc never silently runs with B=0 (which would mark up freight/HUD/tax at 145-150%).
  # name, amount, invoice_reference, single_amount, multi_amount
  DEFAULT_SCHEDULE = [
    ['wheels_axles',     nil, nil,                          500, 1000],
    ['factory_freight',  nil, 'factory_freight',            nil, nil],
    ['dealer_rebate',    nil, nil,                          nil, nil],
    ['ac',               nil, 'ac_from_invoice',            nil, nil],
    ['tax_from_invoice', nil, 'tax_from_invoice',           nil, nil],
    ['hud_fees',         nil, 'hud_fees+state_assoc_fees',  nil, nil],
    ['packs',            nil, nil,                          nil, nil],
    ['advertising',      nil, nil,                          nil, nil],
    ['trim_out',         nil, 'trim_out',                   nil, nil]
  ].freeze

  validates :name, presence: true, inclusion: { in: NAMES }
  validates :amount, :single_amount, :multi_amount, numericality: true, allow_nil: true

  scope :active, -> { where(active: true) }

  # Seed the default deletion schedule for a lender. GAP-FILL ONLY — rows the lender
  # already has (matched on name) are left untouched, so re-running never clobbers
  # dealer-edited amounts. Called from Lender after_create and the backfill runner.
  def self.seed_defaults_for(lender)
    DEFAULT_SCHEDULE.each do |name, amount, ref, single, multi|
      find_or_create_by!(lender: lender, name: name) do |d|
        d.company           = lender.company
        d.amount            = amount
        d.invoice_reference = ref
        d.single_amount     = single
        d.multi_amount      = multi
        d.active            = true
      end
    end
  end
end
