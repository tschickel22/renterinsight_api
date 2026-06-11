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

  # Seed a default markup config for a lender (DB column defaults = the 21st Mortgage
  # schedule: 145% base, VEP0 +5 / VEP1 0 / VEP2 -5, used 140/130). GAP-FILL ONLY —
  # no-op when the lender already has a config, so re-running never clobbers edits.
  # Called from Lender after_create and the backfill runner.
  def self.seed_default_for(lender)
    return if lender.markup_config.present?

    create!(lender: lender, company: lender.company) # column defaults supply the values
  end
end
