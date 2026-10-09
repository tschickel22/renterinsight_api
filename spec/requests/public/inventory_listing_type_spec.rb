# frozen_string_literal: true

require 'rails_helper'

# The inventory block's "Listing types" offers New and Pre-Owned. Those are a
# home's condition, and the feed matched them against listing_type
# (rv / manufactured_home), so a page with New ticked showed no homes at all.
RSpec.describe 'Public inventory listing type', type: :request do
  let(:company) do
    create(:company).tap do |c|
      c.update!(public_inventory_token: SecureRandom.hex(8),
                public_inventory_settings: { 'public_inventory_enabled' => true })
    end
  end

  def home(attrs = {})
    Vehicle.create!({ company: company, year: 2026, make: 'Kabco', model: 'Rubicon', listing_type: 'manufactured_home',
                      vin: "VIN#{SecureRandom.hex(6).upcase}", status: 'available', is_deleted: false,
                      condition: 'new', bedrooms: 3, bathrooms: 2,
                      serial_number: "SN#{SecureRandom.hex(5).upcase}" }.merge(attrs))
  end

  def ids(params)
    get '/public/inventory', params: { token: company.public_inventory_token }.merge(params)
    JSON.parse(response.body)['items'].map { |i| i['id'] }
  end

  it 'reads New as the condition, whatever its case' do
    lower = home(condition: 'new')
    upper = home(condition: 'New')
    home(condition: 'used')

    expect(ids(listing_type: 'new')).to match_array([lower.id, upper.id])
  end

  it 'reads Pre-Owned as used' do
    used = home(condition: 'Used')
    home(condition: 'new')

    expect(ids(listing_type: 'used')).to eq([used.id])
  end

  it 'still filters on a real listing type, and takes several' do
    mh = home
    expect(ids(listing_type: 'manufactured_home')).to eq([mh.id])
    expect(ids(listing_type: 'new,used')).to eq([mh.id])
  end
end
