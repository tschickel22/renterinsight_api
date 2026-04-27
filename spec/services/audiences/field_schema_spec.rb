# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Audiences::FieldSchema do
  describe '.for_source_type' do
    it 'returns LEAD_FIELDS for Lead' do
      expect(described_class.for_source_type('Lead')).to eq(described_class::LEAD_FIELDS)
    end

    it 'returns CONTACT_FIELDS for Contact' do
      expect(described_class.for_source_type('Contact')).to eq(described_class::CONTACT_FIELDS)
    end

    it 'returns ACCOUNT_FIELDS for Account' do
      expect(described_class.for_source_type('Account')).to eq(described_class::ACCOUNT_FIELDS)
    end

    it 'returns [] for unknown source_type' do
      expect(described_class.for_source_type('Foo')).to eq([])
    end

    it 'tags field uses type: tags and tags_* operators' do
      tags_field = described_class::LEAD_FIELDS.find { |f| f[:key] == 'tags' }
      expect(tags_field[:type]).to eq('tags')
      expect(tags_field[:operators]).to match_array(%w[tags_include tags_exclude tags_any_of])
    end

    it 'select fields include options' do
      status = described_class::LEAD_FIELDS.find { |f| f[:key] == 'status' }
      expect(status[:type]).to eq('select')
      expect(status[:options]).to include('new', 'qualified')
    end
  end

  describe '.operators_with_labels' do
    it 'returns the OPERATOR_LABELS hash' do
      labels = described_class.operators_with_labels
      expect(labels['equals']).to eq('is')
      expect(labels['tags_include']).to eq('has tag')
      expect(labels['days_since_greater_than']).to eq('more than X days ago')
    end
  end
end
