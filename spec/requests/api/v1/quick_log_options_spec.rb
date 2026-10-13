# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1 quick log options', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:admin) do
    User.create!(email: "a-#{SecureRandom.hex(4)}@ex.com", first_name: 'A', last_name: 'D', password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: admin.id, company_id: company.id)}", 'Content-Type' => 'application/json' } }

  it 'offers the defaults until the company changes them' do
    get '/api/v1/company/quick-log', headers: headers
    expect(JSON.parse(response.body)['options']).to include('Left Message', 'Set Appointment')
  end

  it 'saves a tidy list, and an empty one stays empty' do
    put '/api/v1/company/quick-log', headers: headers, params: { options: ['  Left  Message ', 'left message', '', 'Toured the lot'] }.to_json
    expect(JSON.parse(response.body)['options']).to eq(['Left Message', 'Toured the lot'])

    put '/api/v1/company/quick-log', headers: headers, params: { options: [] }.to_json
    get '/api/v1/company/quick-log', headers: headers
    expect(JSON.parse(response.body)['options']).to eq([])
  end
end
