# frozen_string_literal: true

require 'rails_helper'

# Platform admins choose which dealers Quinn AI may text for from the shared
# numbers (E96). Live alone sends nothing; a dealer must also be on the list.
RSpec.describe 'Quinn AI shared numbers (platform admin)', type: :request do
  let(:staff) { Company.create!(name: "DT #{SecureRandom.hex(3)}") }
  let(:ops) do
    User.create!(email: "ops-#{SecureRandom.hex(4)}@example.com", first_name: 'Op', last_name: 'Staff', password: 'Pass1234!',
                 company_id: staff.id, role: 'platform_admin', status: 'active')
  end
  let(:dealer) { Company.create!(name: "Keystead #{SecureRandom.hex(3)}") }
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: ops.id, company_id: staff.id)}", 'Content-Type' => 'application/json' } }
  def body = JSON.parse(response.body)

  before do
    Setting.set('Platform', 0, 'assistant_pool',
                { 'live' => false, 'numbers' => [{ 'number' => '+19704632673', 'messaging_service_sid' => 'MGpool' }] })
  end

  it 'adds and removes a dealer and switches the pool on' do
    expect(Assistant::Pool.available_for?(dealer)).to be(false)

    patch '/api/admin/assistant_pool', headers: headers, params: { live: true }.to_json
    expect(body['live']).to be(true)
    expect(Assistant::Pool.available_for?(dealer)).to be(false)

    post "/api/admin/assistant_pool/companies/#{dealer.id}", headers: headers
    expect(body['companies'].map { |c| c['id'] }).to eq([dealer.id])
    expect(body['companies'].first).to include('name' => dealer.name, 'days_left' => nil, 'own_number' => false)
    expect(Assistant::Pool.available_for?(dealer)).to be(true)

    post "/api/admin/assistant_pool/companies/#{dealer.id}", headers: headers
    expect(body['companies'].size).to eq(1)

    delete "/api/admin/assistant_pool/companies/#{dealer.id}", headers: headers
    expect(body['companies']).to eq([])
    expect(Assistant::Pool.available_for?(dealer)).to be(false)
    expect(Assistant::Pool.config['numbers'].size).to eq(1)
  end

  it 'will not switch on a pool with no numbers' do
    Setting.set('Platform', 0, 'assistant_pool', { 'live' => false })
    patch '/api/admin/assistant_pool', headers: headers, params: { live: true }.to_json
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'is for platform admins only' do
    admin = User.create!(email: "a-#{SecureRandom.hex(4)}@example.com", first_name: 'Ada', last_name: 'Admin', password: 'Pass1234!',
                         company_id: dealer.id, role: 'company_admin', status: 'active')
    h = { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: admin.id, company_id: dealer.id)}", 'Content-Type' => 'application/json' }
    post "/api/admin/assistant_pool/companies/#{dealer.id}", headers: h
    expect(response.status).to be >= 400
    expect(Assistant::Pool.company_ids).to eq([])
  end
end
