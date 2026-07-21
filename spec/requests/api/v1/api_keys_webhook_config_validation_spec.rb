# frozen_string_literal: true

require 'rails_helper'

# Guardrails on ApiKeysController when a key with leads:write also carries
# webhook_config: default_location_id is required (no orphaned inbound leads)
# and referenced user/location IDs must belong to the same company.
RSpec.describe 'Api::V1 ApiKeys webhook_config validation', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:other)   { Company.create!(name: "Other-#{SecureRandom.hex(4)}", industry: 'rv') }
  let(:location) { Location.create!(company_id: company.id, name: 'Denver', code: 'DEN', active: true) }
  let(:foreign_location) { Location.create!(company_id: other.id, name: 'ForeignLoc', code: 'FL', active: true) }
  let(:admin) do
    User.create!(email: "a-#{SecureRandom.hex(4)}@example.com", first_name: 'A', last_name: 'A',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:foreign_user) do
    User.create!(email: "f-#{SecureRandom.hex(4)}@example.com", first_name: 'F', last_name: 'F',
                 password: 'Pass1234!', company_id: other.id, role: 'sales_rep')
  end
  let(:token) { JsonWebToken.encode(user_id: admin.id, company_id: company.id) }
  let(:headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }

  before do
    Resource.find_or_create_by(key: 'leads') { |r| r.name = 'Leads'; r.actions = %w[read write] if r.respond_to?(:actions=) }
    Resource.find_or_create_by(key: 'contacts') { |r| r.name = 'Contacts'; r.actions = %w[read write] if r.respond_to?(:actions=) }
  end

  def create_key(webhook_config:, permissions: { leads: %w[read write] })
    post '/api/v1/api-keys',
         params: {
           name: 'zapier', rate_limit: 1000,
           company_id: company.id,          # scope the key to this company
           permissions: permissions,
           webhook_config: webhook_config
         }.to_json,
         headers: headers
  end

  it 'rejects a leads:write key with no default_location_id' do
    create_key(webhook_config: { assignment_mode: 'unassigned', dedupe_enabled: true })
    expect(response).to have_http_status(:unprocessable_entity)
    expect(JSON.parse(response.body)['errors'].join(' ')).to match(/default_location_ids?.*required/i)
  end

  it 'rejects a location from another company' do
    create_key(webhook_config: { default_location_id: foreign_location.id, assignment_mode: 'unassigned' })
    expect(response).to have_http_status(:unprocessable_entity)
    expect(JSON.parse(response.body)['errors'].join(' ')).to include('do not belong to company')
  end

  it 'rejects assigned users from another company' do
    create_key(webhook_config: {
      default_location_id: location.id,
      assignment_mode: 'round_robin',
      assigned_user_ids: [foreign_user.id]
    })
    expect(response).to have_http_status(:unprocessable_entity)
    expect(JSON.parse(response.body)['errors'].join(' ')).to include('not in company')
  end

  it 'accepts a valid config' do
    create_key(webhook_config: {
      default_location_id: location.id,
      assignment_mode: 'unassigned',
      dedupe_enabled: true
    })
    expect(response).to have_http_status(:created)
    body = JSON.parse(response.body)
    expect(body.dig('api_key', 'company_id')).to eq(company.id)
  end

  it 'does not block a key that has no leads:write (validation is scoped)' do
    create_key(webhook_config: {}, permissions: { contacts: %w[read] })
    expect(response).to have_http_status(:created)
  end
end
