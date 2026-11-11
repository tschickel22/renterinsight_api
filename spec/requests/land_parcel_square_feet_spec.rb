# frozen_string_literal: true

require 'rails_helper'

# Land Management takes a lot's size in square feet as well as acres.
RSpec.describe 'Land parcels in square feet', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:admin) do
    User.create!(email: "a-#{SecureRandom.hex(4)}@x.com", first_name: 'A', last_name: 'A',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:headers) do
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: admin.id, company_id: company.id)}",
      'Content-Type' => 'application/json' }
  end

  it 'saves a lot typed in square feet and sends it back that way' do
    post '/api/v1/land-parcels', params: { parcel: { name: 'City lot', status: 'available', sizeUnit: 'sq_ft', squareFeet: 6_000, price: 24_000 } }.to_json, headers: headers
    expect(response).to have_http_status(:created)
    parcel = JSON.parse(response.body)['parcel']
    expect(parcel).to include('sizeUnit' => 'sq_ft', 'squareFeet' => 6000.0, 'sizeLabel' => '6,000 sq ft', 'pricePerSqFt' => 4.0)
    expect(parcel['acreage']).to eq(0.1377)

    patch "/api/v1/land-parcels/#{parcel['id']}", params: { parcel: { sizeUnit: 'acres', acreage: 0.5 } }.to_json, headers: headers
    expect(JSON.parse(response.body)['parcel']).to include('sizeUnit' => 'acres', 'acreage' => 0.5, 'squareFeet' => 21_780.0)
  end
end
