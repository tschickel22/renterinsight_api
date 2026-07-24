# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ImportExport::FieldMapper do
  # Minimal stand-in for ModuleRegistry.fields_for('leads') — just the keys the
  # cases below exercise.
  let(:fields) do
    [
      { key: 'first_name',   label: 'First name' },
      { key: 'last_name',    label: 'Last name' },
      { key: 'email',        label: 'Email' },
      { key: 'phone',        label: 'Phone' },
      { key: 'street',       label: 'Street' },
      { key: 'city',         label: 'City' },
      { key: 'state',        label: 'State' },
      { key: 'zip',          label: 'Zip' },
      { key: 'notes',        label: 'Notes' },
      { key: 'status',       label: 'Status' },
      { key: 'company_name', label: 'Company name' },
      { key: 'title',        label: 'Title' },
      { key: 'source_name',  label: 'Source name' },
      { key: 'tags',         label: 'Tags' }
    ]
  end

  def map(headers)
    described_class.new(headers, fields).call
  end

  describe 'collision handling' do
    # Regression: "Email Follow Up" partial-matched `email` and, because
    # Importer#build_row_hash lets the last non-blank column win, overwrote
    # every real address with free-text follow-up notes.
    it 'leaves the weaker header unmapped when two headers claim one field' do
      result = map(['Email', 'Email Follow Up'])

      expect(result[:suggested_mapping]).to eq('Email' => 'email')
      expect(result[:unmapped_headers]).to eq(['Email Follow Up'])
    end

    it 'lets an exact match win over an alias regardless of column order' do
      result = map(%w[Mobile Phone])

      expect(result[:suggested_mapping]).to eq('Phone' => 'phone')
      expect(result[:unmapped_headers]).to eq(['Mobile'])
    end

    it 'never maps two headers onto the same field' do
      result = map(['Email', 'Email Follow Up', 'Mobile', 'Phone', 'Notes', 'Note'])
      values = result[:suggested_mapping].values

      expect(values).to eq(values.uniq)
    end

    it 'keeps the first header on a tie' do
      result = map(['Notes', 'Note'])

      expect(result[:suggested_mapping]).to eq('Notes' => 'notes')
      expect(result[:unmapped_headers]).to eq(['Note'])
    end
  end

  describe 'matching' do
    it 'matches exact keys and labels' do
      expect(map(%w[Email City])[:suggested_mapping]).to eq('Email' => 'email', 'City' => 'city')
    end

    it 'matches known aliases' do
      result = map(['Lead Source', 'Position', 'Account Name'])

      expect(result[:suggested_mapping]).to eq(
        'Lead Source'  => 'source_name',
        'Position'     => 'title',
        'Account Name' => 'company_name'
      )
    end

    it 'matches a field name appearing as whole words inside a header' do
      result = map(['Zip/Postal Code'])

      expect(result[:suggested_mapping]).to eq('Zip/Postal Code' => 'zip')
    end

    it 'tolerates singular/plural drift' do
      expect(map(['Note'])[:suggested_mapping]).to eq('Note' => 'notes')
    end

    it 'does not match on a mid-word substring' do
      # "competition" contains no whole-word field name; the old raw-substring
      # fallback had no such guarantee.
      result = map(%w[Competition Website])

      expect(result[:suggested_mapping]).to be_empty
      expect(result[:unmapped_headers]).to eq(%w[Competition Website])
    end

    it 'reports genuinely unknown headers as unmapped' do
      result = map(['Demo Set?', 'Visited Booth'])

      expect(result[:unmapped_headers]).to eq(['Demo Set?', 'Visited Booth'])
    end
  end

  describe 'export → import round trip' do
    it 'maps every field label back to its own key' do
      headers = fields.map { |f| f[:label] }
      mapping = map(headers)[:suggested_mapping]

      fields.each { |f| expect(mapping[f[:label]]).to eq(f[:key]) }
    end
  end

  describe 'unmapped_fields' do
    it 'lists fields no header claimed' do
      result = map(%w[Email])

      expect(result[:unmapped_fields].map { |f| f[:key] }).not_to include('email')
      expect(result[:unmapped_fields].map { |f| f[:key] }).to include('phone')
    end
  end
end
