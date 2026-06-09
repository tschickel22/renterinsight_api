# frozen_string_literal: true

require 'rails_helper'

# Regression: the model previously referenced columns that don't exist on the
# (global, minimal) manufacturers table — company_id, created_by_id, contact_name,
# and address fields — which made every save/serialize raise. These specs lock in
# the corrected, schema-aligned model.
RSpec.describe Manufacturer, type: :model do
  it 'creates and normalizes fields' do
    m = Manufacturer.create!(
      name: '  Acme Homes ',
      industry_type: 'manufactured_housing',
      contact_email: ' INFO@Acme.COM ',
      contact_phone: ' 555-1212 ',
      code: ' ah '
    )

    expect(m).to be_persisted
    expect(m.name).to eq('Acme Homes')
    expect(m.contact_email).to eq('info@acme.com')
    expect(m.contact_phone).to eq('555-1212')
    expect(m.code).to eq('AH')
  end

  it 'serializes real columns and omits the ones that never existed' do
    m = Manufacturer.create!(name: 'Acme Homes', industry_type: 'manufactured_housing',
                             code: 'AH', contact_name: 'Warranty Dept')
    json = m.as_json

    expect(json['display_name']).to eq('Acme Homes (AH)')
    expect(json['contact_name']).to eq('Warranty Dept') # real column now
    expect(json).not_to have_key('full_address')        # removed dead method
    expect(json).not_to have_key('company_id')          # never a column on this table
  end

  it 'enforces code uniqueness via validation' do
    Manufacturer.create!(name: 'One', industry_type: 'rv', code: 'DUP')
    dup = Manufacturer.new(name: 'Two', industry_type: 'rv', code: 'DUP')

    expect(dup).not_to be_valid
    expect(dup.errors[:code]).to be_present
  end

  it 'allows multiple manufacturers without a code' do
    Manufacturer.create!(name: 'No Code A', industry_type: 'rv')
    expect { Manufacturer.create!(name: 'No Code B', industry_type: 'rv') }.not_to raise_error
  end
end
