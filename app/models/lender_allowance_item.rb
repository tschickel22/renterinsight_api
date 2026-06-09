# frozen_string_literal: true

# One line of a lender's ALLOWANCE schedule (Max Advance Phase 2). Company-scoped
# child of a Lender. Config only — the calculator that consumes these is a later phase.
class LenderAllowanceItem < ApplicationRecord
  belongs_to :lender
  belongs_to :company
  belongs_to :company_allowance_default, optional: true  # tracks which default this was seeded from

  CATEGORIES = %w[
    options delivery_set trim_out skirting steps_decks footers pad hookups
    freight ac tax hud_fees gutters other
  ].freeze

  PRICING_BASES = %w[flat per_each per_section_single per_section_multi per_material].freeze

  validates :category, presence: true, inclusion: { in: CATEGORIES }
  validates :pricing_basis, inclusion: { in: PRICING_BASES }, allow_nil: true
  validates :standard_allowance, :maximum_allowance,
            :wind_zone2_adder_per_side, :wind_zone3_adder_per_side,
            :dealer_cost, :dealer_price,
            numericality: true, allow_nil: true

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(:position, :name) }
end
