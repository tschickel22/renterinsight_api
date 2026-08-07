# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Websites::CalculatorSettings do
  def company(settings = {})
    instance_double(Company, loan_settings: settings)
  end

  describe '.for' do
    it 'is enabled for a company that has never touched the setting' do
      expect(described_class.for(company)[:enabled]).to be(true)
    end

    it 'is disabled only when explicitly turned off' do
      expect(described_class.for(company('calculator_enabled' => false))[:enabled]).to be(false)
    end

    it 'falls back to defaults for blank values' do
      settings = described_class.for(company('default_interest_rate' => '', 'max_loan_term' => nil))

      expect(settings[:defaultInterestRate]).to eq(6.99)
      expect(settings[:defaultLoanTermMonths]).to eq(240)
    end

    it 'uses the company values when set' do
      settings = described_class.for(
        company('default_interest_rate' => '7.5', 'max_loan_term' => 300, 'calculator_disclaimer_text' => 'Ask us.')
      )

      expect(settings[:defaultInterestRate]).to eq(7.5)
      expect(settings[:defaultLoanTermMonths]).to eq(300)
      expect(settings[:disclaimerText]).to eq('Ask us.')
    end

    it 'drops junk term options rather than offering a zero-month loan' do
      settings = described_class.for(company('calculator_loan_term_options' => [0, '180', -5, 'x']))

      expect(settings[:loanTermOptions]).to eq([180])
    end

    it 'falls back to the standard terms when none survive' do
      expect(described_class.for(company('calculator_loan_term_options' => []))[:loanTermOptions])
        .to eq([120, 180, 240, 300, 360])
    end

    it 'survives a company with no loan settings at all' do
      expect(described_class.for(instance_double(Company, loan_settings: nil))[:enabled]).to be(true)
    end
  end

  describe '#monthly_payment_for' do
    subject(:calc) do
      described_class.new(
        company('default_interest_rate' => 6.0, 'max_loan_term' => 240, 'min_down_payment_percent' => 10)
      )
    end

    # $100,000 less 10% down = $90,000 over 240 months at 6% APR.
    it 'amortises principal and interest' do
      expect(calc.monthly_payment_for(100_000)).to be_within(1.0).of(644.79)
    end

    it 'returns nil rather than zero for an unpriced listing' do
      expect(calc.monthly_payment_for(nil)).to be_nil
      expect(calc.monthly_payment_for(0)).to be_nil
    end

    # Otherwise the amortisation formula divides by zero.
    it 'falls back to straight-line at a zero rate' do
      zero = described_class.new(
        company('default_interest_rate' => 0, 'max_loan_term' => 100, 'min_down_payment_percent' => 0)
      )

      expect(zero.monthly_payment_for(10_000)).to eq(100.0)
    end

    it 'returns nil when the whole price is taken as down payment' do
      full_down = described_class.new(
        company('min_down_payment_percent' => 100, 'max_loan_term' => 240)
      )

      expect(full_down.monthly_payment_for(50_000)).to be_nil
    end
  end
end
