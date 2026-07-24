# frozen_string_literal: true

require 'rails_helper'

# The edit view needs to read a key's inbound-lead routing (location, source,
# rep assignment) to display it and to PATCH a change without wiping the rest.
# api_key_json previously omitted webhook_config entirely, so the UI could
# neither show nor edit where a key's leads landed or who got them.
RSpec.describe 'Api::V1 ApiKeys webhook_config exposure', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:location) { Location.create!(company_id: company.id, name: 'Denver', code: 'DEN', active: true) }
  let(:other_location) { Location.create!(company_id: company.id, name: 'Boulder', code: 'BLD', active: true) }
  let(:admin) do
    User.create!(email: "a-#{SecureRandom.hex(4)}@example.com", first_name: 'A', last_name: 'A',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:rep) do
    User.create!(email: "r-#{SecureRandom.hex(4)}@example.com", first_name: 'R', last_name: 'Rep',
                 password: 'Pass1234!', company_id: company.id, role: 'sales_rep')
  end
  let(:other_rep) do
    User.create!(email: "r2-#{SecureRandom.hex(4)}@example.com", first_name: 'R2', last_name: 'Rep',
                 password: 'Pass1234!', company_id: company.id, role: 'sales_rep')
  end
  let(:token) { JsonWebToken.encode(user_id: admin.id, company_id: company.id) }
  let(:headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }

  before do
    Resource.find_or_create_by(key: 'leads') { |r| r.name = 'Leads'; r.actions = %w[read write] if r.respond_to?(:actions=) }
  end

  # Creates a leads key routed to `location` and assigned to `rep`.
  def create_key
    post '/api/v1/api-keys',
         params: {
           name: "zapier-#{SecureRandom.hex(3)}", rate_limit: 1000,
           company_id: company.id,
           permissions: { leads: %w[read write] },
           webhook_config: {
             default_location_id: location.id,
             assignment_mode: 'specific',
             assigned_user_id: rep.id,
             dedupe_enabled: true
           }
         }.to_json,
         headers: headers
    JSON.parse(response.body)['api_key']
  end

  describe 'GET /api/v1/api-keys/:id' do
    it 'returns the routing config so the edit view can display it' do
      key = create_key

      get "/api/v1/api-keys/#{key['id']}", headers: headers

      expect(response).to have_http_status(:ok)
      cfg = JSON.parse(response.body).dig('api_key', 'webhook_config')
      expect(cfg).to be_present
      expect(cfg['default_location_ids']).to eq([location.id])
      expect(cfg['assignment_mode']).to eq('specific')
      expect(cfg['assigned_user_id']).to eq(rep.id)
    end
  end

  describe 'GET /api/v1/api-keys' do
    it 'includes the routing config on the list payload' do
      create_key

      get '/api/v1/api-keys', headers: headers

      expect(response).to have_http_status(:ok)
      listed = JSON.parse(response.body)['api_keys'].first
      expect(listed['webhook_config']['assigned_user_id']).to eq(rep.id)
    end
  end

  describe 'PATCH /api/v1/api-keys/:id' do
    it 'reassigns the rep and location without touching permissions' do
      key = create_key

      patch "/api/v1/api-keys/#{key['id']}",
            params: {
              webhook_config: {
                default_location_ids: [other_location.id],
                assignment_mode: 'specific',
                assigned_user_id: other_rep.id,
                dedupe_enabled: true
              }
            }.to_json,
            headers: headers

      expect(response).to have_http_status(:ok)
      cfg = JSON.parse(response.body).dig('api_key', 'webhook_config')
      expect(cfg['default_location_ids']).to eq([other_location.id])
      expect(cfg['assigned_user_id']).to eq(other_rep.id)

      expect(ApiKey.find(key['id']).permissions).to be_present
    end

    it 'still rejects clearing the location on a leads key' do
      key = create_key

      patch "/api/v1/api-keys/#{key['id']}",
            params: { webhook_config: { assignment_mode: 'unassigned' } }.to_json,
            headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['errors'].join(' ')).to match(/default_location_ids?.*required/i)
    end
  end
end
