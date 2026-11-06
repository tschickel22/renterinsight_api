# frozen_string_literal: true

require 'rails_helper'

# Saved list filters: an admin who sells sets Owner to All once and the lead,
# contact, account and deal lists open that way at the next login.
RSpec.describe 'Api::V1 list filters', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:other_company) { Company.create!(name: "Other-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'A', last_name: 'B',
                 password: 'Pass1234!', company_id: company.id, role: 'admin', status: 'active')
  end

  def headers(co = company)
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: co.id)}",
      'Content-Type' => 'application/json' }
  end

  it 'saves one list without touching the others and reads them back' do
    put '/api/v1/me/list-filters', params: { list: 'leads', values: { owner: 'all', mine: false } }.to_json, headers: headers
    expect(response.parsed_body['saved']).to be(true)
    put '/api/v1/me/list-filters', params: { list: 'deals', values: { mine: false } }.to_json, headers: headers

    get '/api/v1/me/list-filters', headers: headers
    expect(response.parsed_body['filters']).to eq(
      'leads' => { 'owner' => 'all', 'mine' => false }, 'deals' => { 'mine' => false }
    )
  end

  it 'never stores search text or nested values' do
    put '/api/v1/me/list-filters',
        params: { list: 'contacts', values: { search: 'smith', owner: '12', odd: { a: 1 }, source: nil } }.to_json,
        headers: headers
    expect(user.reload.list_filter_preferences[company.id.to_s]['contacts']).to eq('owner' => '12', 'source' => nil)
  end

  it 'refuses a list it does not know' do
    put '/api/v1/me/list-filters', params: { list: 'invoices', values: {} }.to_json, headers: headers
    expect(response).to have_http_status(:bad_request)
  end
end
