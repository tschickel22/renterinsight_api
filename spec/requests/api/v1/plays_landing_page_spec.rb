# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::Plays promo landing page', type: :request do
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
  let(:location) { company.inbound_lead_location }

  before do
    company.tenant_module_overrides.create!(module_key: 'marketing.landing_pages', is_enabled: true)
    allow(Plays::LeadResponsePlay).to receive(:texting_ready?).and_return(false)
  end

  def body
    JSON.parse(response.body)
  end

  it 'offers the lead response plays that are on as follow-up, then builds the page' do
    post '/api/v1/plays/new_facebook_lead/install', headers: headers,
                                                     params: { answers: { reps_by_location: { location.id.to_s => [rep.id] } } }.to_json
    expect(response).to have_http_status(:created)

    get '/api/v1/plays/promo_landing_page', headers: headers
    expect(body['play']).to include('kind' => 'landing_page', 'available' => true, 'source' => 'Promo landing page')
    expect(body['play']['follow_up_options']).to eq([{ 'key' => 'new_facebook_lead', 'name' => 'New Facebook lead' }])

    post '/api/v1/plays/promo_landing_page/install', headers: headers,
                                                      params: { answers: { content: { title: 'Fall Sale', follow_up_play: 'new_facebook_lead' } } }.to_json
    expect(response).to have_http_status(:created)
    installation = body.dig('play', 'installation')
    expect(installation['page']).to include('path' => '/fall-sale', 'published' => true)
    expect(installation['follow_up_play']).to eq('key' => 'new_facebook_lead', 'name' => 'New Facebook lead')

    get '/api/v1/plays/promo_landing_page/performance', headers: headers
    expect(body['stages'].map { |s| s['key'] }).to eq(%w[sent_form in_follow_up became_deal])
    expect(body['metrics']).to include('leads' => 0, 'published' => true)

    post '/api/v1/plays/promo_landing_page/uninstall', headers: headers
    expect(response).to have_http_status(:ok)
    expect(body.dig('play', 'installation')).to be_nil
  end
end
