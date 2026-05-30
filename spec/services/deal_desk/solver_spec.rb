# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DealDesk::Solver do
  # Simple structure: 20,000 financed straight (no trade/fees/tax) so the levers are easy to reason about.
  let(:base) { { price: 20_000, apr: 6, term_months: 60, tax_rate: 0 } }

  def payment_at(overrides)
    DealDesk::Engine.compute(base.merge(overrides)).monthly_payment
  end

  describe '#solve_by_term' do
    it 'finds the shortest term that meets the target payment (the boundary)' do
      target = 400.0
      res = described_class.new(base).solve_by_term(target_payment: target, max_term: 120)

      expect(res[:met]).to be(true)
      expect(res[:monthly_payment]).to be <= target + 0.01
      # One month shorter would exceed the target -> proves it's the boundary.
      expect(payment_at(term_months: res[:term_months] - 1)).to be > target
    end

    it 'flags met:false when even the longest term cannot reach the target' do
      res = described_class.new(base).solve_by_term(target_payment: 50.0, max_term: 240)
      expect(res[:met]).to be(false)
      expect(res[:term_months]).to eq(240)
    end

    it 'respects an explicit allowed-terms set' do
      res = described_class.new(base).solve_by_term(target_payment: 400.0, allowed_terms: [36, 48, 60, 72])
      expect([36, 48, 60, 72]).to include(res[:term_months])
    end
  end

  describe '#solve_by_cash_down' do
    it 'solves the cash down needed to hit a lower target payment' do
      target = 300.0
      res = described_class.new(base).solve_by_cash_down(target_payment: target)

      expect(res[:met]).to be(true)
      expect(res[:cash_down]).to be > 0
      expect(res[:monthly_payment]).to be_within(1.0).of(target)
    end

    it 'requires no down when the base payment already meets the target' do
      res = described_class.new(base).solve_by_cash_down(target_payment: 1_000.0)
      expect(res[:cash_down]).to eq(0.0)
      expect(res[:met]).to be(true)
    end
  end

  describe '#solve_by_price' do
    let(:taxed_base) { { price: 20_000, apr: 6, term_months: 60, tax_rate: 0.05, tax_mode: :full_price } }

    it 'solves a price/discount that hits the target despite tax coupling' do
      target = 300.0
      res = described_class.new(taxed_base).solve_by_price(target_payment: target)

      expect(res[:met]).to be(true)
      expect(res[:price]).to be < 20_000
      expect(res[:discount]).to be > 0
      expect(res[:monthly_payment]).to be <= target + 0.01
    end

    it 'needs no discount when full price already meets the target' do
      res = described_class.new(taxed_base).solve_by_price(target_payment: 1_000.0)
      expect(res[:discount]).to eq(0.0)
      expect(res[:met]).to be(true)
    end
  end

  describe '#solve_by_rate' do
    it 'evaluates each candidate tier and flags which meet the target' do
      res = described_class.new(base).solve_by_rate(
        target_payment: 390.0,
        candidates: [{ rate: 5, label: 'Tier A' }, { rate: 9, label: 'Tier B' }]
      )

      options = res[:options]
      expect(options.size).to eq(2)
      # Lower rate -> lower payment.
      expect(options.first[:monthly_payment]).to be < options.last[:monthly_payment]
      expect(options.map { |o| o[:label] }).to eq(['Tier A', 'Tier B'])
    end
  end

  describe '#solve_for_payment (dispatch)' do
    it 'routes to the named lever' do
      res = described_class.solve_for_payment(base, lever: :term, target_payment: 400.0, max_term: 120)
      expect(res[:lever]).to eq(:term)
    end

    it 'raises on an unknown lever' do
      expect { described_class.new(base).solve_for_payment(lever: :nonsense, target_payment: 1) }
        .to raise_error(ArgumentError, /unknown lever/)
    end
  end

  describe '#batch_solve' do
    let(:batch_base) { { apr: 7, term_months: 120, tax_rate: 0 } }
    let(:units) do
      [
        { stock_number: 'A1', price: 40_000, unit_cost: 34_000 },
        { stock_number: 'B2', price: 55_000, unit_cost: 47_000 }
      ]
    end

    it 'returns payment and internal gross per candidate unit' do
      rows = described_class.new(batch_base).batch_solve(units, target_payment: 600.0)

      expect(rows.size).to eq(2)
      expect(rows.first[:unit][:stock_number]).to eq('A1')
      expect(rows.first[:monthly_payment]).to be > 0
      expect(rows.first[:gross].total).to be > 0
      expect(rows.first).to have_key(:met)
      # Cheaper unit -> lower payment.
      expect(rows.first[:monthly_payment]).to be < rows.last[:monthly_payment]
    end

    it 'does not echo unit cost back in the unit identifier hash' do
      rows = described_class.new(batch_base).batch_solve(units)
      expect(rows.first[:unit]).not_to have_key(:unit_cost)
    end
  end
end
