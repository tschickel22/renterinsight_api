# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Websites::LotManufacturers do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }

  def vehicle(make, status: 'available', deleted: false)
    company.vehicles.create!(year: 2026, make: make, model: 'M', status: status,
                             is_deleted: deleted, vin: SecureRandom.hex(8).upcase)
  end

  it 'is empty for no company' do
    expect(described_class.for(nil)).to eq([])
  end

  it 'is empty for a lot with no stock' do
    expect(described_class.for(company)).to eq([])
  end

  it 'lists the makes on the lot' do
    vehicle('Clayton Homes')
    vehicle('TRU Homes')

    # Vehicle normalises make to title case on write, so the stored value is
    # "Tru Homes" rather than "TRU Homes". Matching against our marks is
    # case-insensitive for exactly this reason.
    expect(described_class.for(company)).to match_array(['Clayton Homes', 'Tru Homes'])
  end

  # Feed-fed stock lands as available_to_order, so filtering to 'available'
  # would show nothing for a lot that sells to order.
  it 'counts available_to_order stock' do
    vehicle('Champion Homes', status: 'available_to_order')

    expect(described_class.for(company)).to eq(['Champion Homes'])
  end

  it 'ignores sold and soft-deleted stock' do
    vehicle('Clayton Homes', status: 'sold')
    vehicle('Cavco', deleted: true)

    expect(described_class.for(company)).to eq([])
  end

  it 'orders by how much of each make is stocked' do
    3.times { vehicle('Clayton Homes') }
    vehicle('TRU Homes')

    expect(described_class.for(company).first).to eq('Clayton Homes')
  end

  it 'does not reach across companies' do
    other = Company.create!(name: "Other-#{SecureRandom.hex(3)}")
    other.vehicles.create!(year: 2026, make: 'Fleetwood', model: 'M', status: 'available',
                           vin: SecureRandom.hex(8).upcase)

    expect(described_class.for(company)).to eq([])
  end

  # Make is validated as present now, but legacy rows predate that, so the
  # guard stays. update_column bypasses validation to produce one.
  it 'ignores rows with no make' do
    vehicle('Placeholder').update_column(:make, nil)
    vehicle('Clayton Homes')

    expect(described_class.for(company)).to eq(['Clayton Homes'])
  end
end
