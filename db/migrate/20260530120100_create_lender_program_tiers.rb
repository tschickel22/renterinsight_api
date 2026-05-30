# frozen_string_literal: true

# The tier matrix for a lender program: FICO band × collateral age × loan amount →
# rate, max term, max LTV. Each row is one cell of the matrix. Normalizing the matrix
# into its own table (rather than jsonb on lender_programs) keeps the Phase 3 matching
# / solve-by-tier queries straightforward.
#
# Conventions:
#   - fico_min/max:        credit-score band (max nil = open-ended top band)
#   - collateral_age_*:    unit age in YEARS (max nil = open-ended)
#   - loan_amount_*:       financed-amount band in dollars (max nil = open-ended)
#   - rate:                APR as whole-number percent (7.990 = 7.99%)
#   - max_ltv:             RATIO (1.3000 = 130% LTV) — matches Engine guardrail input
class CreateLenderProgramTiers < ActiveRecord::Migration[8.0]
  def change
    create_table :lender_program_tiers do |t|
      t.references :lender_program, null: false, foreign_key: true, index: true
      t.string  :tier_label                                  # e.g. "Tier 1 (720+)"
      t.integer :fico_min
      t.integer :fico_max
      t.integer :collateral_age_min_years, default: 0
      t.integer :collateral_age_max_years
      t.decimal :loan_amount_min, precision: 15, scale: 2, default: 0
      t.decimal :loan_amount_max, precision: 15, scale: 2
      t.decimal :rate,            precision: 6,  scale: 3, null: false  # APR percent
      t.integer :max_term_months, null: false
      t.decimal :max_ltv,         precision: 6,  scale: 4                # ratio (1.30 = 130%)
      t.integer :position,        null: false, default: 0
      t.timestamps
    end

    add_index :lender_program_tiers, [:lender_program_id, :fico_min, :fico_max],
              name: 'index_lender_tiers_on_program_and_fico'
  end
end
