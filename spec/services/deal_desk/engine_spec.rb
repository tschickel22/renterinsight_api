# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DealDesk::Engine do
  # Base structure with negative trade equity, fees, F&I, and tax.
  let(:inputs) do
    {
      price: 50_000,
      trade_allowance: 10_000,
      trade_payoff: 12_000,        # underwater by 2,000 -> rolls in
      cash_down: 5_000,
      rebates: 1_000,
      fees: { doc: 500, title: 100 },
      fni_products: [
        { price: 2_000, cost: 1_200 }, # service contract
        { price: 800,  cost: 300 }     # GAP
      ],
      finance_reserve: 600,
      unit_cost: 42_000,
      pack_amount: 500,
      tax_rate: 0.05,
      tax_mode: :full_price,
      apr: 7.5,
      term_months: 120
    }
  end

  describe '#compute (amount-financed assembly)' do
    subject(:result) { described_class.compute(inputs) }

    it 'sums fees from a hash' do
      expect(result.total_fees).to eq(600.0)
    end

    it 'rolls up F&I product prices' do
      expect(result.total_fni).to eq(2_800.0)
    end

    it 'computes negative trade equity (underwater trade)' do
      expect(result.trade_equity).to eq(-2_000.0)
    end

    it 'taxes the full price by default' do
      expect(result.taxes).to eq(2_500.0) # 50,000 * 5%
    end

    it 'assembles out-the-door = price + fees + F&I + taxes - rebates' do
      expect(result.out_the_door).to eq(54_900.0)
    end

    it 'assembles amount financed = OTD - trade_equity - cash_down (negative equity increases it)' do
      # 54,900 - (-2,000) - 5,000 = 51,900
      expect(result.amount_financed).to eq(51_900.0)
    end

    it 'derives the monthly payment from the shared LoanMath primitive' do
      expected = DealDesk::LoanMath.monthly_payment(principal: 51_900, apr: 7.5, term_months: 120).round(2)
      expect(result.monthly_payment).to eq(expected)
    end
  end

  describe 'tax modes' do
    it 'taxes price-minus-trade when configured' do
      result = described_class.compute(inputs.merge(tax_mode: :price_minus_trade))
      expect(result.taxes).to eq(2_000.0) # (50,000 - 10,000) * 5%
    end

    it 'never taxes below zero when the trade exceeds the price' do
      result = described_class.compute(
        price: 5_000, trade_allowance: 9_000, tax_rate: 0.05, tax_mode: :price_minus_trade, term_months: 12
      )
      expect(result.taxes).to eq(0.0)
    end
  end

  describe 'dealer gross (internal only)' do
    subject(:result) { described_class.compute(inputs) }

    it 'computes front gross = price - cost - pack' do
      expect(result.gross.front).to eq(7_500.0) # 50,000 - 42,000 - 500
    end

    it 'computes back gross = F&I profit + finance reserve' do
      expect(result.gross.back).to eq(1_900.0) # (800 + 500) + 600
    end

    it 'computes total gross' do
      expect(result.gross.total).to eq(9_400.0)
    end

    it 'returns nil gross when no unit cost is supplied' do
      expect(described_class.compute(inputs.except(:unit_cost)).gross).to be_nil
    end

    it 'EXCLUDES gross from the customer-facing projection' do
      expect(result.customer_h).not_to have_key(:gross)
      expect(result.customer_h.keys).to include(:amount_financed, :monthly_payment, :out_the_door)
    end
  end

  describe '#guardrails' do
    subject(:engine) { described_class.new(inputs) }

    it 'passes minimum gross when total gross meets the floor' do
      checks = engine.guardrails(min_gross: 5_000)
      expect(checks[:passed]).to be(true)
    end

    it 'fails minimum gross when total gross is below the floor' do
      checks = engine.guardrails(min_gross: 10_000)
      expect(checks[:passed]).to be(false)
      expect(checks[:checks].first[:reason]).to match(/below minimum gross/)
    end

    it 'evaluates max LTV against collateral value' do
      pass = engine.guardrails(max_ltv: 1.2, collateral_value: 50_000)
      fail = engine.guardrails(max_ltv: 1.0, collateral_value: 50_000)
      expect(pass[:passed]).to be(true)   # 51,900 / 50,000 = 1.038
      expect(fail[:passed]).to be(false)
    end

    it 'evaluates payment-to-income' do
      pass = engine.guardrails(max_pti: 0.20, monthly_income: 5_000)
      fail = engine.guardrails(max_pti: 0.10, monthly_income: 5_000)
      expect(pass[:passed]).to be(true)
      expect(fail[:passed]).to be(false)
    end

    it 'skips checks whose thresholds are nil' do
      expect(engine.guardrails[:checks]).to be_empty
    end
  end
end
