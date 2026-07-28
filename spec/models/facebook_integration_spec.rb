# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FacebookIntegration, type: :model do
  let(:company) { create(:company) }

  def integration(page_id:, page_name:, created_at:, status: 'active', is_deleted: false)
    described_class.create!(
      company:    company,
      page_id:    page_id,
      page_name:  page_name,
      status:     status,
      is_deleted: is_deleted,
      created_at: created_at,
      updated_at: created_at
    )
  end

  describe '.current_for' do
    it 'returns the most recently connected Page, not the oldest' do
      integration(page_id: '111', page_name: 'Old Page',  created_at: 2.months.ago)
      newest = integration(page_id: '222', page_name: 'New Page', created_at: 1.day.ago)

      expect(described_class.current_for(company)).to eq(newest)
    end

    it 'ignores disconnected and soft-deleted rows' do
      integration(page_id: '111', page_name: 'Retired',  created_at: 1.hour.ago,
                  status: 'disconnected', is_deleted: true)
      live = integration(page_id: '222', page_name: 'Live', created_at: 2.days.ago)

      expect(described_class.current_for(company)).to eq(live)
    end

    it 'returns nil when the company has no active connection' do
      integration(page_id: '111', page_name: 'Retired', created_at: 1.hour.ago,
                  status: 'disconnected', is_deleted: true)

      expect(described_class.current_for(company)).to be_nil
    end

    it 'returns nil for a nil company' do
      expect(described_class.current_for(nil)).to be_nil
    end

    it 'does not leak another company\'s connection' do
      other = create(:company)
      described_class.create!(company: other, page_id: '999', page_name: 'Other Co')

      expect(described_class.current_for(company)).to be_nil
    end
  end
end
