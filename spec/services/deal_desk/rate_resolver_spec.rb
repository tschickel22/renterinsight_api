# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DealDesk::RateResolver do
  describe '.resolve' do
    it 'prefers an explicit manual override' do
      expect(described_class.resolve(tier_rate: 7.0, company_default: 8.0, manual_override: 5.5)).to eq(5.5)
    end

    it 'falls back to the lender tier rate when no override' do
      expect(described_class.resolve(tier_rate: 7.0, company_default: 8.0)).to eq(7.0)
    end

    it 'falls back to the company default when no tier rate' do
      expect(described_class.resolve(company_default: 8.0)).to eq(8.0)
    end

    it 'honors a 0% manual override (not treated as missing)' do
      expect(described_class.resolve(tier_rate: 7.0, manual_override: 0.0)).to eq(0.0)
    end

    it 'returns nil when no source provides a rate' do
      expect(described_class.resolve).to be_nil
    end
  end

  describe '.resolve_with_source' do
    it 'reports which source won' do
      expect(described_class.resolve_with_source(tier_rate: 7.0, company_default: 8.0, manual_override: 5.5))
        .to eq(rate: 5.5, source: :manual_override)
      expect(described_class.resolve_with_source(tier_rate: 7.0, company_default: 8.0))
        .to eq(rate: 7.0, source: :tier)
      expect(described_class.resolve_with_source(company_default: 8.0))
        .to eq(rate: 8.0, source: :company_default)
      expect(described_class.resolve_with_source).to eq(rate: nil, source: nil)
    end
  end
end
