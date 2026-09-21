# frozen_string_literal: true

require 'rails_helper'

# The chat assistant appeared on every landing page of any company with the
# module, with no off switch and captioned with the marketing container's
# internal name ("Acme Homes Landing Pages"), which nobody chose.
RSpec.describe 'Api::V1::LandingPages settings', type: :request do
  let(:company) { Company.create!(name: "LPSet-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:token) { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }

  before do
    company.tenant_module_overrides.create!(module_key: 'marketing.landing_pages', is_enabled: true)
    allow_any_instance_of(ModuleAccessService).to receive(:module_enabled?).and_call_original
    allow_any_instance_of(ModuleAccessService).to receive(:module_enabled?).with('marketing.ai_concierge').and_return(true)
  end

  def json = JSON.parse(response.body)

  it 'answers with the defaults before any landing page exists' do
    get '/api/v1/landing_pages/settings', headers: headers

    expect(response).to have_http_status(:ok)
    expect(json['concierge']).to include('available' => true, 'enabled' => true, 'name' => '')
    expect(json['concierge']['resolved_name']).to eq(company.name)
  end

  it 'turns the assistant off and names it, and says so on the public payload' do
    patch '/api/v1/landing_pages/settings',
          params: { concierge: { enabled: false, name: 'Ask Summit' } }.to_json, headers: headers

    expect(response).to have_http_status(:ok)
    expect(json['concierge']).to include('enabled' => false, 'name' => 'Ask Summit', 'resolved_name' => 'Ask Summit')

    site = Website.active.marketing_containers.find_by(company_id: company.id)
    payload = Websites::PublicPayload.for(site)
    expect(payload['concierge_enabled']).to be false
    expect(payload['concierge_name']).to eq('Ask Summit')
  end

  it 'turns it back on, and the widget keeps the name it was given' do
    patch '/api/v1/landing_pages/settings',
          params: { concierge: { enabled: false, name: 'Ask Summit' } }.to_json, headers: headers
    patch '/api/v1/landing_pages/settings',
          params: { concierge: { enabled: true } }.to_json, headers: headers

    site = Website.active.marketing_containers.find_by(company_id: company.id)
    payload = Websites::PublicPayload.for(site)
    expect(payload['concierge_enabled']).to be true
    expect(payload['concierge_name']).to eq('Ask Summit')
  end

  # A name is a label, not an on switch: clearing it falls back rather than
  # leaving the widget captioned with nothing.
  it 'falls back to the company name when the name is cleared' do
    patch '/api/v1/landing_pages/settings',
          params: { concierge: { name: '   ' } }.to_json, headers: headers

    expect(json['concierge']['resolved_name']).to eq(company.name)
  end

  it 'still reports the module as unavailable when the dealer has not bought it' do
    allow_any_instance_of(ModuleAccessService).to receive(:module_enabled?).with('marketing.ai_concierge').and_return(false)

    get '/api/v1/landing_pages/settings', headers: headers

    expect(json['concierge']['available']).to be false
  end
end
