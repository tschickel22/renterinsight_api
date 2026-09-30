# frozen_string_literal: true

module Truebuild
  # A buyer's monthly payment estimate on the dealer's own calculator
  # settings (rate, term, down payment, on or off, disclaimer): the same
  # figure their site's payment calculator and listing cards show.
  class PaymentEstimate
    def initialize(company)
      @calculator = Websites::CalculatorSettings.new(company)
      @settings = @calculator.to_h
    end

    def enabled? = @settings[:enabled]

    def terms
      { down_pct: @settings[:minDownPaymentPercent].to_f, apr: @settings[:defaultInterestRate].to_f,
        years: (@settings[:defaultLoanTermMonths].to_i / 12.0).round(1), disclaimer: @settings[:disclaimerText] }
    end

    def monthly(total)
      return nil unless enabled?

      @calculator.monthly_payment_for(total)&.round
    end
  end
end
