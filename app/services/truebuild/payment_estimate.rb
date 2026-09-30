# frozen_string_literal: true

module Truebuild
  # A monthly payment estimate for a buyer, on the same assumptions as the
  # site builder's payment calculator: 10% down, 7.5% APR, 20 years. Labelled
  # an estimate wherever it is shown; not an offer of credit.
  module PaymentEstimate
    module_function

    DOWN_PCT = 10
    APR = 7.5
    YEARS = 20

    def terms = { down_pct: DOWN_PCT, apr: APR, years: YEARS }

    def monthly(total)
      return nil unless total.to_f.positive?

      principal = total.to_f * (1 - DOWN_PCT / 100.0)
      rate = APR / 100.0 / 12
      n = YEARS * 12
      (principal * rate / (1 - ((1 + rate)**-n))).round
    end
  end
end
