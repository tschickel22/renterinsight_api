# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::Plays board and demo clock', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin', status: 'active')
  end
  let(:headers) do
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}", 'Content-Type' => 'application/json' }
  end

  def body
    JSON.parse(response.body)
  end

  it 'turns the demo clock on only for a demo company, and the board shows it' do
    patch '/api/v1/plays/demo_clock', headers: headers, params: { enabled: true }.to_json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body['error']).to eq('The demo clock only runs on demo companies.')

    company.update!(is_demo: true)
    patch '/api/v1/plays/demo_clock', headers: headers, params: { enabled: true }.to_json
    expect(response).to have_http_status(:ok)
    expect(body).to eq('available' => true, 'enabled' => true)

    get '/api/v1/plays/board', headers: headers
    expect(response).to have_http_status(:ok)
    expect(body['demo_clock']).to eq('available' => true, 'enabled' => true)
    expect(body['columns'].size).to eq(7)
    expect(body['cards']).to eq([])
  end
end
