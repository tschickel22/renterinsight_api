# frozen_string_literal: true

require 'rails_helper'

# Inventory statuses are labels: a dealer's words change, the stored value does not.
RSpec.describe InventoryStatusNames do
  let(:company) do
    Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing').tap do |c|
      c.update!(public_inventory_token: SecureRandom.hex(8),
                public_inventory_settings: { 'public_inventory_enabled' => true, 'public_statuses' => %w[available] })
    end
  end

  it 'calls an available home In Stock by default' do
    expect(described_class.new(company).for('available')).to eq('In Stock')
    expect(described_class.new(company).for('available_to_order')).to eq('Available to Order')
  end

  it 'keeps Available where a unit is not stock' do
    %w[saas property_management storage].each do |industry|
      expect(Company::LABEL_DEFAULTS[industry]['status_available']).to eq('Available')
    end
  end

  it 'covers every stored status' do
    keys = Vehicle::STATUSES.map { |status| "status_#{status}" }
    expect(Company::LABEL_DEFAULTS['manufactured_housing'].keys).to include(*keys)
    expect(Company::LABEL_DEFAULTS['installer']['status_available']).to eq('In Stock')
  end

  it 'uses the name the dealer chose' do
    company.save_label_overrides('status_available' => 'On the Lot')
    expect(described_class.new(company).for('available')).to eq('On the Lot')
  end

  it 'changes the public name and leaves the stored value alone', type: :request do
    company.save_label_overrides('status_available' => 'On the Lot')
    Vehicle.create!(company: company, year: 2026, make: 'Champion', model: 'Status Test', vin: "VIN#{SecureRandom.hex(6)}",
                    status: 'available', is_deleted: false, listing_type: 'manufactured_home', bedrooms: 3, bathrooms: 2, msrp: 80_000)

    get '/public/inventory', params: { token: company.public_inventory_token, statuses: 'available' }
    item = JSON.parse(response.body)['items'].first
    expect(item).to include('status' => 'available', 'status_label' => 'On the Lot')
  end
end
