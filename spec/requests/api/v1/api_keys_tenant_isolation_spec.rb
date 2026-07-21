# frozen_string_literal: true

require 'rails_helper'

# Regression spec for the tenant leak in ApiKeysController#index:
# a platform_admin viewing Company A's settings used to see Company B's
# API keys because the controller fell through to ApiKey.all whenever the
# caller was a platform admin, ignoring the active @company scope.
RSpec.describe 'Api::V1 ApiKeys tenant isolation', type: :request do
  let(:company_a) { Company.create!(name: "A-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:company_b) { Company.create!(name: "B-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:platform_admin) do
    User.create!(email: "pa-#{SecureRandom.hex(4)}@example.com", first_name: 'P', last_name: 'A',
                 password: 'Pass1234!', company_id: company_a.id, role: 'platform_admin')
  end
  let(:token_for_a) { JsonWebToken.encode(user_id: platform_admin.id, company_id: company_a.id) }
  let(:token_for_b) { JsonWebToken.encode(user_id: platform_admin.id, company_id: company_b.id) }

  let!(:key_a) { ApiKey.new(company_id: company_a.id, name: 'A-key', key: "ri_live_#{SecureRandom.hex(24)}", created_by_user_id: platform_admin.id, permissions: {}).tap { |k| k.save!(validate: false) } }
  let!(:key_b) { ApiKey.new(company_id: company_b.id, name: 'B-key', key: "ri_live_#{SecureRandom.hex(24)}", created_by_user_id: platform_admin.id, permissions: {}).tap { |k| k.save!(validate: false) } }

  it 'platform admin viewing Company A only sees Company A keys' do
    get '/api/v1/api-keys', headers: { 'Authorization' => "Bearer #{token_for_a}" }
    expect(response).to have_http_status(:ok)
    names = JSON.parse(response.body)['api_keys'].map { |k| k['name'] }
    expect(names).to include('A-key')
    expect(names).not_to include('B-key')
  end

  it 'platform admin viewing Company B only sees Company B keys' do
    get '/api/v1/api-keys', headers: { 'Authorization' => "Bearer #{token_for_b}" }
    expect(response).to have_http_status(:ok)
    names = JSON.parse(response.body)['api_keys'].map { |k| k['name'] }
    expect(names).to include('B-key')
    expect(names).not_to include('A-key')
  end

  it 'platform admin can explicitly cross-scope with ?company_id=all' do
    get '/api/v1/api-keys?company_id=all', headers: { 'Authorization' => "Bearer #{token_for_a}" }
    expect(response).to have_http_status(:ok)
    names = JSON.parse(response.body)['api_keys'].map { |k| k['name'] }
    expect(names).to include('A-key', 'B-key')
  end
end
