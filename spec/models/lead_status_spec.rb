# frozen_string_literal: true

require 'rails_helper'

RSpec.describe LeadStatus, type: :model do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }

  describe 'sort_order default' do
    it 'assigns max+10 when created without an explicit sort_order' do
      LeadStatus.create!(company: company, key: 'new',      label: 'New',      sort_order: 10)
      LeadStatus.create!(company: company, key: 'contact', label: 'Contact',  sort_order: 20)

      s = LeadStatus.create!(company: company, key: 'hot_lead', label: 'Hot Lead')
      expect(s.sort_order).to eq(30)
    end

    it 'respects an explicit sort_order when provided' do
      LeadStatus.create!(company: company, key: 'new', label: 'New', sort_order: 10)
      s = LeadStatus.create!(company: company, key: 'hot_lead', label: 'Hot Lead', sort_order: 5)
      expect(s.sort_order).to eq(5)
    end

    it 'starts at 10 for the very first status in a company' do
      s = LeadStatus.create!(company: company, key: 'new', label: 'New')
      expect(s.sort_order).to eq(10)
    end
  end

  describe 'label uniqueness' do
    it 'rejects a duplicate label in the same company (case-insensitive)' do
      LeadStatus.create!(company: company, key: 'interested', label: 'Hot Lead', sort_order: 30)
      dup = LeadStatus.new(company: company, key: 'hot_lead', label: 'hot lead')
      expect(dup.save).to be false
      expect(dup.errors[:label].join).to include('already exists')
    end

    it 'allows the same label in a different company' do
      other = Company.create!(name: "Other-#{SecureRandom.hex(4)}", industry: 'rv')
      LeadStatus.create!(company: company, key: 'hot_lead', label: 'Hot Lead')
      expect(LeadStatus.new(company: other, key: 'hot_lead', label: 'Hot Lead').valid?).to be true
    end

    it 'allows updating a status without triggering self-duplicate' do
      s = LeadStatus.create!(company: company, key: 'hot_lead', label: 'Hot Lead')
      expect(s.update(label: 'Hot Lead')).to be true # same label on itself
    end
  end
end
