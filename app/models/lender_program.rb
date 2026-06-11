# frozen_string_literal: true

# A lender financing program. Carries a tier matrix (LenderProgramTier) of
# FICO band × collateral age × loan amount → rate / max term / max LTV.
# @company-scoped. Seeded samples are flagged is_seeded: true and swappable.
class LenderProgram < ApplicationRecord
  COLLATERAL_TYPES = %w[rv manufactured_home all].freeze

  belongs_to :company
  has_many :tiers, -> { order(:position) }, class_name: 'LenderProgramTier', dependent: :destroy

  validates :lender_name, :program_name, presence: true
  validates :collateral_type, inclusion: { in: COLLATERAL_TYPES }, allow_nil: true

  scope :active, -> { where(active: true) }
  scope :seeded, -> { where(is_seeded: true) }
  scope :for_collateral, ->(type) { where(collateral_type: [type, 'all', nil]) }
  scope :ordered, -> { order(:position, :lender_name) }

  # Best-matching tier for a borrower/collateral/loan profile, or nil.
  def tier_for(fico:, collateral_age_years:, loan_amount:)
    tiers.detect { |t| t.matches?(fico: fico, collateral_age_years: collateral_age_years, loan_amount: loan_amount) }
  end
end
