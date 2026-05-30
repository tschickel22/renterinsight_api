# frozen_string_literal: true

module DealDesk
  # Reverse solvers: given a base structure and a target monthly payment, solve a single
  # lever (term / cash down / price / lender rate) for the value that hits the target.
  # Also batch-solve: one structure against N candidate units.
  #
  # Pure — composes Engine + LoanMath only. Every solver returns a plain Hash with the
  # solved lever, the resulting payment, and a `met:` flag (false when the lever can't
  # reach the target within its bounds — the caller decides what to do about it).
  class Solver
    DEFAULT_MAX_TERM = 240

    def initialize(base_inputs = {})
      # Normalize once via the Engine, then clone/merge per solve.
      @base = Engine.new(base_inputs).in
    end

    def self.solve_for_payment(base_inputs, lever:, target_payment:, **opts)
      new(base_inputs).solve_for_payment(lever: lever, target_payment: target_payment, **opts)
    end

    # Dispatch to a specific lever.
    def solve_for_payment(lever:, target_payment:, **opts)
      case lever.to_sym
      when :term     then solve_by_term(target_payment: target_payment, **opts)
      when :cash_down then solve_by_cash_down(target_payment: target_payment, **opts)
      when :price    then solve_by_price(target_payment: target_payment, **opts)
      when :rate     then solve_by_rate(target_payment: target_payment, **opts)
      else
        raise ArgumentError, "unknown lever: #{lever.inspect}"
      end
    end

    # Shortest term whose payment is <= target (least interest while still meeting the
    # ceiling). Payment is monotonically decreasing in term.
    def solve_by_term(target_payment:, max_term: DEFAULT_MAX_TERM, allowed_terms: nil)
      target = target_payment.to_f
      terms = (allowed_terms || (1..max_term).to_a).map(&:to_i).sort.uniq
      chosen = terms.find { |t| compute(term_months: t).monthly_payment <= target }

      met = !chosen.nil?
      term = chosen || terms.last
      r = compute(term_months: term)
      { lever: :term, term_months: term, monthly_payment: r.monthly_payment,
        amount_financed: r.amount_financed, met: met }
    end

    # Cash down that hits the target. amount_financed is linear in cash_down, so invert
    # the amortization for the required principal and back out the down.
    def solve_by_cash_down(target_payment:)
      target = target_payment.to_f
      af_zero = compute(cash_down: 0.0).amount_financed
      required_principal = LoanMath.principal_for_payment(
        payment: target, apr: @base[:apr], term_months: @base[:term_months]
      )
      down = (af_zero - required_principal).round(2)
      down = 0.0 if down.negative?
      down = af_zero if down > af_zero # can't put more down than the financed amount

      r = compute(cash_down: down)
      # met when, at this down, payment is at or below target (within a cent).
      { lever: :cash_down, cash_down: down, monthly_payment: r.monthly_payment,
        amount_financed: r.amount_financed, met: r.monthly_payment <= target + 0.01 }
    end

    # Price/discount that hits the target. Price couples to taxes (in :full_price mode),
    # so solve by bisection rather than a closed form. Payment is monotonically
    # increasing in price.
    def solve_by_price(target_payment:, min_price: 0.0, iterations: 100)
      target = target_payment.to_f
      hi = @base[:price]
      lo = min_price.to_f

      # Already at/under target at full price → no discount needed.
      return price_result(hi, target) if compute(price: hi).monthly_payment <= target + 0.01
      # Even at the floor price we can't get there → return the floor, met: false.
      return price_result(lo, target, met: false) if compute(price: lo).monthly_payment > target

      iterations.times do
        mid = (lo + hi) / 2.0
        if compute(price: mid).monthly_payment > target
          hi = mid
        else
          lo = mid
        end
      end
      price_result(lo.round(2), target)
    end

    # Evaluate each candidate lender rate/tier. Lower rate => lower payment.
    # candidates: Array of { rate:, label?:, max_term?:, max_ltv?: }.
    def solve_by_rate(target_payment:, candidates:)
      target = target_payment.to_f
      options = Array(candidates).map do |c|
        c = c.transform_keys(&:to_sym)
        r = compute(apr: c[:rate].to_f)
        {
          label: c[:label], rate: c[:rate].to_f,
          monthly_payment: r.monthly_payment, amount_financed: r.amount_financed,
          met: r.monthly_payment <= target + 0.01
        }
      end
      { lever: :rate, options: options }
    end

    # One structure against N candidate units. Each unit is a Hash of overrides
    # (price, unit_cost, pack_amount, plus any identifier keys to echo back).
    # Returns payment + internal gross per unit (gross is internal-only — strip before
    # sending to a customer).
    def batch_solve(units, target_payment: nil)
      Array(units).map do |unit|
        overrides = unit.transform_keys(&:to_sym)
        r = compute(**overrides.slice(:price, :unit_cost, :pack_amount, :apr, :term_months,
                                      :cash_down, :trade_allowance, :trade_payoff, :rebates))
        row = {
          unit: overrides.except(:unit_cost, :pack_amount), # echo identifiers, hide cost
          monthly_payment: r.monthly_payment,
          amount_financed: r.amount_financed,
          out_the_door: r.out_the_door,
          gross: r.gross # INTERNAL ONLY
        }
        row[:met] = r.monthly_payment <= target_payment.to_f + 0.01 unless target_payment.nil?
        row
      end
    end

    private

    def compute(**overrides)
      Engine.new(@base.merge(overrides)).compute
    end

    def price_result(price, target, met: nil)
      r = compute(price: price)
      met = r.monthly_payment <= target + 0.01 if met.nil?
      {
        lever: :price, price: price.round(2),
        discount: (@base[:price] - price).round(2),
        monthly_payment: r.monthly_payment, amount_financed: r.amount_financed, met: met
      }
    end
  end
end
