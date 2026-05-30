# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DealDesk::LoanMath do
  describe '.monthly_payment' do
    it 'computes the standard amortized payment' do
      # 10,000 @ 6% APR over 12 months ≈ 860.66
      expect(described_class.monthly_payment(principal: 10_000, apr: 6, term_months: 12))
        .to be_within(0.01).of(860.66)
    end

    it 'treats a 0% APR as simple division' do
      expect(described_class.monthly_payment(principal: 1_200, apr: 0, term_months: 12)).to eq(100.0)
    end

    it 'returns 0.0 when principal is zero' do
      expect(described_class.monthly_payment(principal: 0, apr: 6, term_months: 12)).to eq(0.0)
    end

    it 'returns 0.0 when term is zero' do
      expect(described_class.monthly_payment(principal: 10_000, apr: 6, term_months: 0)).to eq(0.0)
    end

    it 'supports long RV terms (240 months) without overflow' do
      payment = described_class.monthly_payment(principal: 250_000, apr: 7.99, term_months: 240)
      expect(payment).to be > 0
      expect(payment).to be_finite
    end

    it 'coerces string and decimal inputs' do
      expect(described_class.monthly_payment(principal: '10000', apr: '6', term_months: '12'))
        .to be_within(0.01).of(860.66)
    end
  end

  describe '.principal_for_payment' do
    it 'is the inverse of monthly_payment' do
      principal = 51_900
      payment = described_class.monthly_payment(principal: principal, apr: 7.5, term_months: 120)
      recovered = described_class.principal_for_payment(payment: payment, apr: 7.5, term_months: 120)
      expect(recovered).to be_within(0.01).of(principal)
    end

    it 'handles 0% APR' do
      expect(described_class.principal_for_payment(payment: 100, apr: 0, term_months: 12)).to eq(1_200.0)
    end

    it 'returns 0.0 when payment is zero' do
      expect(described_class.principal_for_payment(payment: 0, apr: 6, term_months: 12)).to eq(0.0)
    end
  end

  describe '.total_interest' do
    it 'returns payments minus principal' do
      expect(described_class.total_interest(monthly_payment: 100, term_months: 12, principal: 1_100))
        .to eq(100.0)
    end

    it 'returns 0.0 when term is zero' do
      expect(described_class.total_interest(monthly_payment: 100, term_months: 0, principal: 1_000)).to eq(0.0)
    end
  end
end
