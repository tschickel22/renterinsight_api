# frozen_string_literal: true

module DealDesk
  # Pure amortization primitives. No ActiveRecord, no DB, no Rails dependencies.
  #
  # This is the SINGLE shared amortization implementation for the app. Loan#calculate_monthly_payment
  # delegates here so the loans module and the Deal Desk never drift apart.
  #
  # Convention: `apr` is a whole-number percent (e.g. 7.99 means 7.99%), matching the existing
  # Loan#interest_rate column. Money values are plain numerics; callers round for display.
  module LoanMath
    module_function

    # Standard amortizing-loan monthly payment.
    #   PMT = P * [r(1 + r)^n] / [(1 + r)^n - 1]
    # Returns an unrounded Float so callers (incl. Loan) can round as they see fit.
    #
    # Mirrors the exact formula previously inlined in Loan#calculate_monthly_payment.
    # Supports long RV terms (e.g. 240 months) — Float exponentiation does not overflow.
    def monthly_payment(principal:, apr:, term_months:)
      principal = principal.to_f
      term = term_months.to_i
      return 0.0 if principal.zero? || term.zero?

      rate = apr.to_f
      if rate.zero?
        principal / term
      else
        r = (rate / 100.0) / 12.0
        n = term
        (principal * (r * (1 + r)**n)) / ((1 + r)**n - 1)
      end
    end

    # Inverse of monthly_payment: given a target payment, APR and term, what principal
    # (amount financed) produces that payment? Used by the reverse solvers.
    def principal_for_payment(payment:, apr:, term_months:)
      payment = payment.to_f
      term = term_months.to_i
      return 0.0 if payment.zero? || term.zero?

      rate = apr.to_f
      if rate.zero?
        payment * term
      else
        r = (rate / 100.0) / 12.0
        n = term
        payment * ((1 + r)**n - 1) / (r * (1 + r)**n)
      end
    end

    # Total interest paid over the life of the loan given a fixed payment.
    def total_interest(monthly_payment:, term_months:, principal:)
      payment = monthly_payment.to_f
      term = term_months.to_i
      return 0.0 if payment.zero? || term.zero?

      (payment * term) - principal.to_f
    end
  end
end
