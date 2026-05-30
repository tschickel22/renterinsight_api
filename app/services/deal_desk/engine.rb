# frozen_string_literal: true

module DealDesk
  # Pure deal-structuring engine. Given a set of inputs (price, trade, fees, F&I, taxes,
  # APR, term), assembles the amount financed, computes the monthly payment, out-the-door
  # price, and — separately — the internal dealer gross. No ActiveRecord, no DB.
  #
  #   amount_financed = price + fees + F&I + taxes − rebates − trade_equity − cash_down
  #   trade_equity    = trade_allowance − trade_payoff   (negative equity rolls in)
  #   monthly_payment = LoanMath.monthly_payment(amount_financed, apr, term)
  #
  # DEALER GROSS IS INTERNAL ONLY. It lives in a separate Gross struct and is excluded
  # from Result#customer_h. Customer-facing serializers must use customer_h, never to_h.
  #
  # Inputs (Hash, string- or symbol-keyed; all money optional and default 0):
  #   price            selling price of the unit
  #   trade_allowance  trade-in allowance credited to the buyer
  #   trade_payoff     lien payoff on the trade (negative-equity rollover)
  #   cash_down        cash down payment
  #   rebates          manufacturer/dealer rebates
  #   fees             Numeric, or Hash of named fees (doc/title/license/prep/...) summed
  #   fni_products     Array of { price:, cost: } — service contract, GAP, tire/wheel, paint/fabric
  #   finance_reserve  dealer finance reserve (back-end gross)
  #   unit_cost        dealer cost of the unit (front-end gross; omit to skip gross)
  #   pack_amount      dealer pack (reduces front gross)
  #   tax_rate         effective combined tax rate as a fraction (0.0825 = 8.25%)
  #   tax_mode         :full_price (default) or :price_minus_trade
  #   apr              resolved APR, whole-number percent (see RateResolver)
  #   term_months      loan term in months (RV: up to 240)
  class Engine
    TAX_MODES = %i[full_price price_minus_trade].freeze

    Gross = Struct.new(:front, :back, :total, keyword_init: true)

    Result = Struct.new(
      :amount_financed, :monthly_payment, :out_the_door,
      :taxes, :total_fees, :total_fni, :trade_equity, :total_interest,
      :apr, :term_months, :gross,
      keyword_init: true
    ) do
      # Customer-safe projection — NEVER includes dealer gross/margin.
      def customer_h
        {
          amount_financed: amount_financed,
          monthly_payment: monthly_payment,
          out_the_door: out_the_door,
          taxes: taxes,
          total_fees: total_fees,
          total_fni: total_fni,
          trade_equity: trade_equity,
          total_interest: total_interest,
          apr: apr,
          term_months: term_months
        }
      end
    end

    def initialize(inputs = {})
      @in = normalize(inputs)
    end

    def self.compute(inputs = {})
      new(inputs).compute
    end

    def compute
      fees   = total_fees
      fni    = total_fni
      equity = trade_equity
      tax    = taxes
      otd    = round2(@in[:price] + fees + fni + tax - @in[:rebates])
      financed = round2(otd - equity - @in[:cash_down])
      financed = 0.0 if financed.negative?

      payment = round2(LoanMath.monthly_payment(
        principal: financed, apr: @in[:apr], term_months: @in[:term_months]
      ))

      Result.new(
        amount_financed: financed,
        monthly_payment: payment,
        out_the_door: otd,
        taxes: tax,
        total_fees: fees,
        total_fni: fni,
        trade_equity: equity,
        total_interest: round2(LoanMath.total_interest(
          monthly_payment: payment, term_months: @in[:term_months], principal: financed
        )),
        apr: @in[:apr],
        term_months: @in[:term_months],
        gross: gross
      )
    end

    # Internal-only. Returns nil when no unit_cost was supplied (gross indeterminate).
    def gross
      return nil if @in[:unit_cost].nil?

      front = round2(@in[:price] - @in[:unit_cost] - @in[:pack_amount])
      back  = round2(fni_profit + @in[:finance_reserve])
      Gross.new(front: front, back: back, total: round2(front + back))
    end

    # Guardrail evaluation. Any threshold left nil is skipped. Returns:
    #   { passed: Bool, checks: [ { name:, pass:, value:, threshold:, reason: } ] }
    def guardrails(min_gross: nil, max_ltv: nil, collateral_value: nil, monthly_income: nil, max_pti: nil)
      result = compute
      checks = []

      unless min_gross.nil?
        g = result.gross&.total
        pass = !g.nil? && g >= min_gross.to_f
        checks << {
          name: :min_gross, pass: pass, value: g, threshold: min_gross.to_f,
          reason: g.nil? ? 'gross unavailable (no unit cost)' : (pass ? 'meets minimum gross' : 'below minimum gross')
        }
      end

      unless max_ltv.nil?
        cv = collateral_value.to_f
        ltv = cv.positive? ? round2(result.amount_financed / cv) : nil
        pass = !ltv.nil? && ltv <= max_ltv.to_f
        checks << {
          name: :max_ltv, pass: pass, value: ltv, threshold: max_ltv.to_f,
          reason: ltv.nil? ? 'collateral value required' : (pass ? 'within max LTV' : 'exceeds max LTV')
        }
      end

      unless max_pti.nil?
        mi = monthly_income.to_f
        pti = mi.positive? ? round2(result.monthly_payment / mi) : nil
        pass = !pti.nil? && pti <= max_pti.to_f
        checks << {
          name: :max_pti, pass: pass, value: pti, threshold: max_pti.to_f,
          reason: pti.nil? ? 'monthly income required' : (pass ? 'within payment-to-income' : 'exceeds payment-to-income')
        }
      end

      { passed: checks.all? { |c| c[:pass] }, checks: checks }
    end

    # Sub-totals (public so the solver and tests can reach them).
    def total_fees
      round2(@in[:fees])
    end

    def total_fni
      round2(@in[:fni_products].sum { |p| p[:price].to_f })
    end

    def fni_profit
      round2(@in[:fni_products].sum { |p| p[:price].to_f - p[:cost].to_f })
    end

    def trade_equity
      round2(@in[:trade_allowance] - @in[:trade_payoff])
    end

    def taxes
      base =
        if @in[:tax_mode] == :price_minus_trade
          [@in[:price] - @in[:trade_allowance], 0.0].max
        else
          @in[:price]
        end
      round2(base * @in[:tax_rate])
    end

    # Normalized inputs (symbol-keyed, coerced). Exposed for the solver to clone/merge.
    attr_reader :in

    private

    def normalize(raw)
      h = raw.each_with_object({}) { |(k, v), acc| acc[k.to_sym] = v }

      fees =
        case h[:fees]
        when Hash then h[:fees].values.sum(&:to_f)
        when nil  then 0.0
        else h[:fees].to_f
        end

      fni = Array(h[:fni_products]).map do |p|
        p = p.transform_keys(&:to_sym)
        { price: p[:price].to_f, cost: p[:cost].to_f }
      end

      mode = (h[:tax_mode] || :full_price).to_sym
      mode = :full_price unless TAX_MODES.include?(mode)

      {
        price: h[:price].to_f,
        trade_allowance: h[:trade_allowance].to_f,
        trade_payoff: h[:trade_payoff].to_f,
        cash_down: h[:cash_down].to_f,
        rebates: h[:rebates].to_f,
        fees: fees,
        fni_products: fni,
        finance_reserve: h[:finance_reserve].to_f,
        unit_cost: h[:unit_cost].nil? ? nil : h[:unit_cost].to_f,
        pack_amount: h[:pack_amount].to_f,
        tax_rate: h[:tax_rate].to_f,
        tax_mode: mode,
        apr: h[:apr].to_f,
        term_months: h[:term_months].to_i
      }
    end

    def round2(value)
      value.to_f.round(2)
    end
  end
end
