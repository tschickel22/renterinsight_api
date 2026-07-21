# frozen_string_literal: true

require 'rails_helper'

# POST /api/v1/api-keys/bulk — fan-out create for multi-location dealers.
# One request produces N keys (one per location) so the dealer can set up
# separate Zaps per location without generating each key individually.
RSpec.describe 'Api::V1 ApiKeys bulk create', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:loc1)    { Location.create!(company_id: company.id, name: 'Denver', code: 'DEN', active: true) }
  let(:loc2)    { Location.create!(company_id: company.id, name: 'Aurora', code: 'AUR', active: true) }
  let(:loc3)    { Location.create!(company_id: company.id, name: 'Boulder', code: 'BLD', active: true) }
  let(:admin) do
    User.create!(email: "a-#{SecureRandom.hex(4)}@example.com", first_name: 'A', last_name: 'A',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:token) { JsonWebToken.encode(user_id: admin.id, company_id: company.id) }
  let(:headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }

  before do
    Resource.find_or_create_by(key: 'leads') { |r| r.name = 'Leads'; r.actions = %w[read write] if r.respond_to?(:actions=) }
  end

  it 'creates one key per location with the shared config baked in' do
    post '/api/v1/api-keys/bulk',
         params: {
           name: 'Facebook Lead Ads',
           company_id: company.id,
           rate_limit: 500,
           permissions: { leads: %w[read write] },
           location_ids: [loc1.id, loc2.id, loc3.id],
           webhook_config: { assignment_mode: 'unassigned', dedupe_enabled: true }
         }.to_json,
         headers: headers

    expect(response).to have_http_status(:created)
    body = JSON.parse(response.body)
    expect(body['api_keys'].length).to eq(3)

    # Each key is scoped to exactly one location and reveals a bearer token.
    body['api_keys'].each do |k|
      expect(k['key']).to match(/\Ari_live_/)
      expect(k['name']).to include('Facebook Lead Ads —')
      expect(Array(k.dig('permissions', 'leads'))).to include('read', 'write')
    end

    # Locations are distinct across keys, matching the input.
    location_ids_on_keys = body['api_keys'].map { |k| k['location_id'] }.sort
    expect(location_ids_on_keys).to eq([loc1.id, loc2.id, loc3.id].sort)
  end

  it 'rolls back all keys if any location is invalid (no half-created state)' do
    other = Company.create!(name: "Other-#{SecureRandom.hex(4)}", industry: 'rv')
    foreign_loc = Location.create!(company_id: other.id, name: 'Foreign', code: 'FGN', active: true)

    expect {
      post '/api/v1/api-keys/bulk',
           params: {
             name: 'FB',
             company_id: company.id,
             rate_limit: 500,
             permissions: { leads: %w[read write] },
             location_ids: [loc1.id, foreign_loc.id],
             webhook_config: { assignment_mode: 'unassigned' }
           }.to_json,
           headers: headers
    }.not_to change { ApiKey.count }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(JSON.parse(response.body)['errors'].join(' ')).to include('do not belong to company')
  end

  it 'rejects when location_ids is empty' do
    post '/api/v1/api-keys/bulk',
         params: {
           name: 'FB',
           company_id: company.id,
           rate_limit: 500,
           permissions: { leads: %w[read write] },
           location_ids: [],
           webhook_config: {}
         }.to_json,
         headers: headers

    expect(response).to have_http_status(:unprocessable_entity)
    expect(JSON.parse(response.body)['errors'].join(' ')).to include('location_ids is required')
  end
end
