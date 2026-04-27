# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Messaging::MergeFieldRegistry do
  describe '.for_source_type' do
    it 'returns Lead-applicable fields for Lead' do
      keys = described_class.for_source_type('Lead').map { |f| f[:key] }
      expect(keys).to include('first_name', 'last_name', 'email', 'phone', 'rep_name', 'company.name')
      expect(keys).not_to include('account_name')
    end

    it 'returns only Account-applicable fields for Account' do
      keys = described_class.for_source_type('Account').map { |f| f[:key] }
      expect(keys).to include('full_name', 'rep_name', 'company.name', 'account_name')
      expect(keys).not_to include('first_name', 'last_name', 'email', 'phone')
    end

    it 'filters by channel: sms removes email-only fields' do
      keys = described_class.for_source_type('Lead', channel: 'sms').map { |f| f[:key] }
      expect(keys).not_to include('unsubscribe_url', 'view_in_browser_url', 'rep_email', 'company.email', 'company.website', 'email')
      expect(keys).to include('first_name', 'phone', 'rep_phone')
    end

    it 'filters by channel: email removes sms-only fields' do
      keys = described_class.for_source_type('Lead', channel: 'email').map { |f| f[:key] }
      expect(keys).not_to include('phone')
      expect(keys).to include('email', 'unsubscribe_url')
    end

    it 'returns empty for unknown source_type' do
      expect(described_class.for_source_type('Foo')).to eq([])
    end
  end

  describe '.grouped_for_source_type' do
    it 'returns a hash grouped by group label' do
      grouped = described_class.grouped_for_source_type('Lead')
      expect(grouped).to be_a(Hash)
      expect(grouped.keys).to include('Recipient', 'Sales rep', 'Company', 'System')
      expect(grouped['Recipient'].map { |f| f[:key] }).to include('first_name', 'last_name')
    end
  end
end
