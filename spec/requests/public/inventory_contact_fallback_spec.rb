# frozen_string_literal: true

require 'rails_helper'

# How to reach the dealer about a home, on the page and the printed sheet. A
# dealer's homes often sit on a location created with a name and nothing else,
# which left the sheet with no phone, email or address at all.
RSpec.describe 'Public inventory contact details', type: :request do
  let(:company) do
    create(:company, name: 'Easy Homesource').tap do |c|
      c.update!(public_inventory_token: SecureRandom.hex(8),
                public_inventory_settings: { 'public_inventory_enabled' => true },
                phone: '(352) 558-8888', email: 'info@easyhomesource.com',
                address_line1: '9011 McIntyre Rd', city: 'Brooksville', state: 'FL', zip_code: '34601')
    end
  end
  let!(:corporate) { Location.ensure_corporate_for(company).tap { |l| l.update!(name: 'Corporate', active: true) } }
  let!(:vehicle) do
    Vehicle.create!(company: company, year: 2026, make: 'Clayton', model: 'Cadence', location: corporate,
                    width: 28, length: 60,
                    vin: "VIN#{SecureRandom.hex(6).upcase}", status: 'available', is_deleted: false)
  end

  def contact
    get "/public/inventory/#{vehicle.id}", params: { token: company.public_inventory_token, company_id: company.id }
    JSON.parse(response.body)['company']
  end

  it "uses the company's details where the location has none" do
    expect(contact).to include('phone' => '(352) 558-8888', 'email' => 'info@easyhomesource.com',
                               'address' => '9011 McIntyre Rd', 'city' => 'Brooksville',
                               'full_address' => '9011 McIntyre Rd, Brooksville, FL, 34601',
                               'location_name' => 'Corporate')
  end

  # Quoted as width by length; only the length was sent.
  it "sends the home's width with its length" do
    get "/public/inventory/#{vehicle.id}", params: { token: company.public_inventory_token, company_id: company.id }
    expect(JSON.parse(response.body)['vehicle'].values_at('width', 'length')).to eq([28, 60])
  end

  it "prefers the location's own, and takes an address whole from one record" do
    corporate.update!(phone: '(352) 555-0100', address_line1: '1 Lot Rd', city: 'Hernando', state: 'FL', zip_code: '34442')

    expect(contact).to include('phone' => '(352) 555-0100', 'email' => 'info@easyhomesource.com',
                               'full_address' => '1 Lot Rd, Hernando, FL, 34442')
  end
end
