# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1 bank feeds (connect a bank)', type: :request do
  let(:company) { Company.create!(name: "BF-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "bf-#{SecureRandom.hex(4)}@example.com", first_name: 'B', last_name: 'F',
                 password: 'Pass1234!', company_id: company.id, role: 'company_admin')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" } }

  it 'starts a session and connects every account it holds' do
    service = instance_double(StripeBankFeedService)
    allow(StripeBankFeedService).to receive(:new).with(company).and_return(service)
    allow(service).to receive(:create_company_session).and_return(client_secret: 'secret', session_id: 'fcsess_1')
    bank = company.bank_accounts.create!(bank_name: 'Wells Fargo Visa', account_type: 'credit_card', account_purpose: 'sync_only')
    allow(service).to receive(:connect_session_accounts!).with('fcsess_1')
                                                           .and_return([{ bank_account: bank, status: 'created', name: bank.bank_name }])

    post '/api/v1/bank_feeds/session', headers: headers
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).to include('client_secret' => 'secret', 'session_id' => 'fcsess_1')

    post '/api/v1/bank_feeds/connect', params: { session_id: 'fcsess_1' }, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)['accounts']).to eq([
      { 'status' => 'created', 'name' => 'Wells Fargo Visa', 'reason' => nil, 'bank_account_id' => bank.id,
        'account_type' => 'credit_card', 'institution_name' => nil, 'account_mask' => nil }
    ])
  end

  it 'needs a session id' do
    post '/api/v1/bank_feeds/connect', params: {}, headers: headers, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
  end
end
