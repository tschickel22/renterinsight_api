# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::Plays readiness', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin', status: 'active')
  end
  let(:headers) do
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}", 'Content-Type' => 'application/json' }
  end

  before { allow(Plays::LeadResponsePlay).to receive(:texting_ready?).and_return(false) }

  it 'returns the checks for a play, with where to fix each' do
    get '/api/v1/plays/walk_in_visit/readiness', headers: headers

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body['ready']).to be true
    texting = body['checks'].find { |c| c['key'] == 'texting' }
    expect(texting).to include('status' => 'warn', 'fix' => { 'label' => 'Set up email and texting', 'path' => '/settings?tab=communications' })
  end
end
