# frozen_string_literal: true

require 'rails_helper'

# Cross-sell inventory: when two locations share a physical lot, a vehicle
# physically assigned to one location should appear in the inventory list
# (and in pickers/dropdowns served by the same endpoint) when the user has
# selected EITHER of the linked locations in the header location selector.
#
# Symmetric — linking via Location A's settings UI also makes A's inventory
# visible from B's selector.
RSpec.describe 'Api::V1::Vehicles cross-sell inventory', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(
      email: "u-#{SecureRandom.hex(4)}@example.com",
      first_name: 'T', last_name: 'U',
      password: 'Pass1234!', company_id: company.id,
      role: 'platform_admin'
    )
  end
  let(:token) { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:auth_headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }

  let!(:loc_a) { Location.create!(company_id: company.id, name: 'Evangeline', code: "EVA-#{SecureRandom.hex(2)}", active: true) }
  let!(:loc_b) { Location.create!(company_id: company.id, name: 'Homes To Geaux', code: "HTG-#{SecureRandom.hex(2)}", active: true) }
  let!(:loc_c) { Location.create!(company_id: company.id, name: 'Unrelated', code: "UNR-#{SecureRandom.hex(2)}", active: true) }

  let!(:veh_at_a) do
    Vehicle.create!(
      company_id: company.id, location_id: loc_a.id,
      listing_type: 'manufactured_home', status: 'available',
      year: 2024, make: 'Skyline', model: 'A1',
      serial_number: "SN-A-#{SecureRandom.hex(4)}", bedrooms: 3, bathrooms: 2
    )
  end
  let!(:veh_at_b) do
    Vehicle.create!(
      company_id: company.id, location_id: loc_b.id,
      listing_type: 'manufactured_home', status: 'available',
      year: 2024, make: 'Skyline', model: 'B1',
      serial_number: "SN-B-#{SecureRandom.hex(4)}", bedrooms: 3, bathrooms: 2
    )
  end
  let!(:veh_at_c) do
    Vehicle.create!(
      company_id: company.id, location_id: loc_c.id,
      listing_type: 'manufactured_home', status: 'available',
      year: 2024, make: 'Skyline', model: 'C1',
      serial_number: "SN-C-#{SecureRandom.hex(4)}", bedrooms: 3, bathrooms: 2
    )
  end

  def vehicle_ids_for(location_id)
    get '/api/v1/vehicles', headers: auth_headers.merge('X-Location-ID' => location_id.to_s)
    expect(response).to have_http_status(:ok)
    JSON.parse(response.body)['vehicles'].map { |v| v['id'].to_i }
  end

  context 'without any sharing groups configured' do
    it 'shows only the selected location\'s inventory' do
      expect(vehicle_ids_for(loc_a.id)).to contain_exactly(veh_at_a.id)
      expect(vehicle_ids_for(loc_b.id)).to contain_exactly(veh_at_b.id)
    end
  end

  context 'when A and B are linked into a sharing group' do
    before { company.set_inventory_sharing_for_location!(loc_a.id, [loc_b.id]) }

    it 'shows both A and B inventory when A is selected' do
      expect(vehicle_ids_for(loc_a.id)).to contain_exactly(veh_at_a.id, veh_at_b.id)
    end

    it 'shows both A and B inventory when B is selected (symmetric)' do
      expect(vehicle_ids_for(loc_b.id)).to contain_exactly(veh_at_a.id, veh_at_b.id)
    end

    it 'still excludes inventory from an unrelated location' do
      ids = vehicle_ids_for(loc_a.id)
      expect(ids).not_to include(veh_at_c.id)
    end

    it 'leaves the unrelated location\'s selector unaffected' do
      expect(vehicle_ids_for(loc_c.id)).to contain_exactly(veh_at_c.id)
    end
  end

  context 'set_vehicle (single vehicle access)' do
    # set_vehicle gates show/update/destroy for non-admin RBAC users by
    # location. The expansion should apply there too, but our test user is a
    # platform_admin (skips that branch). Still, the basic "can fetch" path
    # should work for cross-location inventory.
    before { company.set_inventory_sharing_for_location!(loc_a.id, [loc_b.id]) }

    it 'allows fetching B\'s vehicle when A is the selected location' do
      get "/api/v1/vehicles/#{veh_at_b.id}",
          headers: auth_headers.merge('X-Location-ID' => loc_a.id.to_s)
      expect(response).to have_http_status(:ok)
    end
  end
end
