# frozen_string_literal: true

# A lender's MARKUP / VEP configuration (Max Advance Phase 2). Exactly one per lender
# (enforced by a unique index). Company-scoped child of a Lender. Config only — the
# calculator that consumes these factors is a later phase.
class LenderMarkupConfig < ApplicationRecord
  belongs_to :lender
  belongs_to :company

  validates :lender_id, uniqueness: true
  validates :base_markup_pct, :vep0_adj_pct, :vep1_adj_pct, :vep2_adj_pct,
            :used_onsite_factor_pct, :used_delivered_factor_pct,
            numericality: true, allow_nil: true
  validates :max_age_years, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
end
