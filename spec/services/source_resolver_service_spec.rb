# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SourceResolverService, type: :service do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let!(:fb)       { Source.create!(company_id: company.id, name: 'Facebook Lead Ads', is_active: true) }
  let!(:google)   { Source.create!(company_id: company.id, name: 'Google Business',   is_active: true) }
  let!(:website)  { Source.create!(company_id: company.id, name: 'Website Contact',    is_active: true) }

  describe '.resolve — priority chain' do
    it 'uses explicit source_id when valid for this company' do
      result = described_class.resolve(company: company, source_id: google.id, source_name: 'Facebook Lead Ads')
      expect(result).to eq(google) # source_id wins over source_name
    end

    it 'ignores source_id from another company and falls through' do
      other = Company.create!(name: "Other-#{SecureRandom.hex(4)}", industry: 'rv')
      foreign = Source.create!(company_id: other.id, name: 'Foreign', is_active: true)

      result = described_class.resolve(company: company, source_id: foreign.id, source_name: 'Facebook Lead Ads')
      expect(result).to eq(fb) # falls through to name match
    end

    it 'falls back to default_source_id when neither id nor name resolves' do
      result = described_class.resolve(company: company, default_source_id: website.id)
      expect(result).to eq(website)
    end

    it 'falls back to a "Web Form" source when nothing else works (auto-creates it)' do
      result = described_class.resolve(company: company)
      expect(result.name).to eq('Web Form')
      expect(result.company_id).to eq(company.id)
    end
  end

  describe '.resolve — name matching' do
    it 'exact-matches ignoring case and punctuation' do
      result = described_class.resolve(company: company, source_name: 'facebook lead ads')
      expect(result).to eq(fb)
    end

    it 'substring-matches shorter incoming to longer catalog name' do
      # incoming "Facebook" is contained in catalog "Facebook Lead Ads"
      result = described_class.resolve(company: company, source_name: 'Facebook')
      expect(result).to eq(fb)
    end

    it 'substring-matches longer incoming to shorter catalog name' do
      # incoming "Google Business Profile" contains catalog "Google Business"
      result = described_class.resolve(company: company, source_name: 'Google Business Profile')
      expect(result).to eq(google)
    end

    it 'Levenshtein-matches typos within threshold' do
      # "Facebok" vs "Facebook" — distance 1 (missing 'o')
      result = described_class.resolve(company: company, source_name: 'Facebok Lead Ads')
      expect(result).to eq(fb)
    end

    it 'auto-creates a new Source when no fuzzy match is close enough' do
      expect {
        result = described_class.resolve(company: company, source_name: 'TikTok Organic')
        expect(result.name).to eq('TikTok Organic')
        expect(result.company_id).to eq(company.id)
        expect(result.is_active).to eq(true)
      }.to change { company.sources.count }.by(1)
    end

    it 'auto-creation is stable — same name resolves back to the created row on next call' do
      first = described_class.resolve(company: company, source_name: 'TikTok Organic')
      second = described_class.resolve(company: company, source_name: 'TikTok Organic')
      expect(second).to eq(first)
      expect(company.sources.where(name: 'TikTok Organic').count).to eq(1)
    end
  end
end
