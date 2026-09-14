# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::Plays', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin', status: 'active')
  end
  let(:rep) do
    User.create!(email: "r-#{SecureRandom.hex(4)}@example.com", first_name: 'R', last_name: 'P',
                 password: 'Pass1234!', company_id: company.id, role: 'sales_rep', status: 'active')
  end
  let(:token)   { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }
  let(:location) { company.locations.find_by(is_default: true) }

  before do
    allow(Plays::NewLeadAnyChannel).to receive(:texting_ready?).and_return(false)
  end

  it 'lists the flagship play, off' do
    get '/api/v1/plays', headers: headers

    expect(response).to have_http_status(:ok)
    play = JSON.parse(response.body)['plays'].first
    expect(play).to include('key' => 'new_lead_any_channel', 'texting_ready' => false, 'installation' => nil)
    expect(play['channels'].map { |c| c['key'] }).to include('website', 'facebook')
  end

  it 'turns the play on and returns the forms it created' do
    post '/api/v1/plays/new_lead_any_channel/install', headers: headers, params: {
      answers: { channels: ['website'], reps_by_location: { location.id.to_s => [rep.id] }, call_within_minutes: 15 }
    }.to_json

    expect(response).to have_http_status(:created)
    installation = JSON.parse(response.body).dig('play', 'installation')
    expect(installation['status']).to eq('active')
    expect(installation['answers']['send_texts']).to be false
    expect(installation['intake_forms'].first).to include('source' => 'Website')
  end

  it 'explains what is missing' do
    post '/api/v1/plays/new_lead_any_channel/install', headers: headers, params: { answers: { channels: [] } }.to_json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(JSON.parse(response.body)['error']).to eq('Choose at least one channel.')
  end

  it 'turns the play off' do
    post '/api/v1/plays/new_lead_any_channel/install', headers: headers, params: {
      answers: { channels: ['google'], reps_by_location: { location.id.to_s => [rep.id] } }
    }.to_json

    post '/api/v1/plays/new_lead_any_channel/uninstall', headers: headers

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body).dig('play', 'installation')).to be_nil
  end
end
