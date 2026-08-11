# frozen_string_literal: true

require 'rails_helper'

# An order home carries no price until it is quoted. `sync_vehicle_pricing` used to
# assign the vehicle's (nil) price over the deal's own numbers, which turned the
# explicit `value: 0` the deal form sends into nil. `validates :value, numericality`
# has no allow_nil, so every deal written against an unpriced home came back 422 with
# "Value is not a number" and the salesperson just saw nothing happen.
# Evangeline (company 17) had 237 available_to_order homes in that state.
RSpec.describe 'Deal creation against an unpriced vehicle', type: :model do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:location) { company.locations.create!(name: 'Showroom', timezone: 'America/Denver') }
  let(:account) { company.accounts.create!(name: 'Rylee Buyer') }

  let(:unpriced_vehicle) do
    company.vehicles.create!(listing_type: 'manufactured_home', status: 'available_to_order', year: 2026,
                             make: 'Sunshine Homes', model: 'The Robin Jr.', bedrooms: 3, bathrooms: 2.0,
                             serial_number: "SN-#{SecureRandom.hex(4)}",
                             sale_price: nil, msrp: nil, location_id: location.id)
  end

  let(:priced_vehicle) do
    company.vehicles.create!(listing_type: 'manufactured_home', status: 'available', year: 2026,
                             make: 'Kabco', model: 'MDPG', bedrooms: 3, bathrooms: 2.0, serial_number: "SN-#{SecureRandom.hex(4)}",
                             sale_price: 174_990, location_id: location.id)
  end

  it 'saves a deal on a home that has no price yet' do
    deal = company.deals.new(name: 'Rylee Thibodeaux and Warren Kibodeaux II', account: account,
                             vehicle: unpriced_vehicle, value: 0, location_id: location.id)

    expect(deal.save).to be(true), -> { "expected save, got errors: #{deal.errors.full_messages.join(', ')}" }
    expect(deal.value).to eq(0)
  end

  it 'leaves value non-nil even when the form sends no value at all' do
    deal = company.deals.create!(name: 'No value given', account: account,
                                 vehicle: unpriced_vehicle, location_id: location.id)

    expect(deal.value).not_to be_nil
  end

  it 'still bootstraps value from a vehicle that does have a price' do
    deal = company.deals.create!(name: 'Priced home', account: account,
                                 vehicle: priced_vehicle, value: 0, location_id: location.id)

    expect(deal.value).to eq(174_990)
    expect(deal.selling_price).to eq(174_990)
  end

  it 'does not overwrite a value the user typed' do
    deal = company.deals.create!(name: 'User priced', account: account,
                                 vehicle: priced_vehicle, value: 150_000, location_id: location.id)

    expect(deal.value).to eq(150_000)
  end
end
