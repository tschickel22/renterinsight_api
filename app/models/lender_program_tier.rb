# frozen_string_literal: true

# One cell of a lender program's tier matrix. nil on an upper bound means "open-ended".
#   rate:    APR percent (7.99)
#   max_ltv: ratio (1.30 = 130%) — feeds DealDesk::Engine guardrails directly
class LenderProgramTier < ApplicationRecord
  belongs_to :lender_program

  validates :rate, :max_term_months, presence: true

  scope :ordered, -> { order(:position) }

  # Does this tier apply to the given borrower/collateral/loan profile?
  def matches?(fico:, collateral_age_years:, loan_amount:)
    in_band?(fico,                 fico_min,            fico_max) &&
      in_band?(collateral_age_years, collateral_age_min_years, collateral_age_max_years) &&
      in_band?(loan_amount,          loan_amount_min,     loan_amount_max)
  end

  private

  # Inclusive band check; nil min => 0/open low, nil max => open high; nil value => skip.
  def in_band?(value, min, max)
    return true if value.nil?

    value = value.to_f
    (min.nil? || value >= min.to_f) && (max.nil? || value <= max.to_f)
  end
end
