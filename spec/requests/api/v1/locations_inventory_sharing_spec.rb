# frozen_string_literal: true

require 'rails_helper'

# When the Location settings form posts `linked_inventory_location_ids`,
# LocationsController#update should persist it to the Company's
# inventory_sharing_groups Setting. The relationship is symmetric: editing
# either side produces the same group.
RSpec.describe 'Api::V1::Locations inventory sharing', type: :request do
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
  let(:auth_headers) do
    { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' }
  end

  let!(:loc_a) { Location.create!(company_id: company.id, name: 'Evangeline', code: "EVA-#{SecureRandom.hex(2)}", active: true) }
  let!(:loc_b) { Location.create!(company_id: company.id, name: 'Homes To Geaux', code: "HTG-#{SecureRandom.hex(2)}", active: true) }
  let!(:loc_c) { Location.create!(company_id: company.id, name: 'Third', code: "THR-#{SecureRandom.hex(2)}", active: true) }

  it 'persists linked_inventory_location_ids from the location update payload' do
    patch "/api/v1/locations/#{loc_a.id}",
          params: { location: { linked_inventory_location_ids: [loc_b.id] } }.to_json,
          headers: auth_headers

    expect(response).to have_http_status(:ok)
    expect(company.reload.inventory_visible_location_ids(loc_a.id))
      .to contain_exactly(loc_a.id, loc_b.id)
  end

  it 'returns the current peers in the location_json response' do
    company.set_inventory_sharing_for_location!(loc_a.id, [loc_b.id])

    get "/api/v1/locations/#{loc_a.id}", headers: auth_headers
    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body['location']['linked_inventory_location_ids']).to contain_exactly(loc_b.id)
  end

  it 'clears the relationship when an empty array is posted' do
    company.set_inventory_sharing_for_location!(loc_a.id, [loc_b.id])

    patch "/api/v1/locations/#{loc_a.id}",
          params: { location: { linked_inventory_location_ids: [] } }.to_json,
          headers: auth_headers

    expect(response).to have_http_status(:ok)
    expect(company.reload.inventory_visible_location_ids(loc_a.id)).to eq([loc_a.id])
  end

  it 'leaves the sharing relationship untouched when the param is absent' do
    company.set_inventory_sharing_for_location!(loc_a.id, [loc_b.id])

    patch "/api/v1/locations/#{loc_a.id}",
          params: { location: { name: 'Evangeline Renamed' } }.to_json,
          headers: auth_headers

    expect(response).to have_http_status(:ok)
    expect(company.reload.inventory_visible_location_ids(loc_a.id))
      .to contain_exactly(loc_a.id, loc_b.id)
  end
end
