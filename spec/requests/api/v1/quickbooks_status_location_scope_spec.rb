# frozen_string_literal: true

require 'rails_helper'

# A company that connects QuickBooks per location, asked for its status with
# no location named (the QuickBooks switch's first step asks this way).
RSpec.describe 'GET /api/v1/integrations/quickbooks/status, location scope', type: :request do
  let(:company) do
    Company.create!(name: "Homes-#{SecureRandom.hex(4)}", industry: 'manufactured_housing', quickbooks_scope: 'location')
  end
  let!(:corporate) { company.locations.create!(name: 'Corporate') }
  let!(:main) { company.locations.create!(name: 'Main Location') }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'Pay', last_name: 'Ton',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" } }

  def json = JSON.parse(response.body)

  def connect(location, realm)
    allow_any_instance_of(Location).to receive(:quickbooks_company_name).and_return('EHS Books')
    location.update!(quickbooks_realm_id: realm, quickbooks_access_token_encrypted: 'tok', quickbooks_connected_at: Time.current)
  end

  it 'reports the one connected location' do
    connect(main, '9130')
    get '/api/v1/integrations/quickbooks/status', headers: headers
    expect(response).to have_http_status(:ok)
    expect(json).to include('connected' => true, 'entity_type' => 'location', 'entity_name' => 'Main Location')
  end

  it 'still reports not connected when no location is connected' do
    get '/api/v1/integrations/quickbooks/status', headers: headers
    expect(json['connected']).to be(false)
  end

  it 'reports not connected when locations hold different QuickBooks companies' do
    connect(main, '9130')
    connect(corporate, '7777')
    get '/api/v1/integrations/quickbooks/status', headers: headers
    expect(json['connected']).to be(false)
  end

  it 'answers for the named location when one is asked for' do
    connect(main, '9130')
    get '/api/v1/integrations/quickbooks/status', params: { location_id: corporate.id }, headers: headers
    expect(json).to include('connected' => false, 'entity_name' => 'Corporate')
  end
end
