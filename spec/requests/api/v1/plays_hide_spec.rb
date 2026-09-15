# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::Plays hide, remove and the weekly default', type: :request do
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
  let(:reps) { { company.inbound_lead_location.id.to_s => [rep.id] } }

  before { allow(Plays::LeadResponsePlay).to receive(:texting_ready?).and_return(false) }

  def body
    JSON.parse(response.body)
  end

  def listed_keys(params = '')
    get "/api/v1/plays#{params}", headers: headers
    body['plays'].map { |p| p['key'] }
  end

  it 'turns on the weekly homes email with a lead response play when asked' do
    get '/api/v1/plays/new_facebook_lead', headers: headers
    expect(body.dig('play', 'weekly_homes_on')).to be false

    post '/api/v1/plays/new_facebook_lead/install', headers: headers,
                                                     params: { answers: { reps_by_location: reps }, turn_on_weekly_homes: true }.to_json

    expect(response).to have_http_status(:created)
    expect(body['notices']).to eq(['Weekly homes email is on too.'])
    expect(PlayInstallation.active.exists?(company_id: company.id, play_key: 'weekly_homes_email')).to be true
    expect(body.dig('play', 'weekly_homes_on')).to be true
  end

  it 'leaves the weekly homes email alone when not asked' do
    post '/api/v1/plays/walk_in_visit/install', headers: headers, params: { answers: { reps_by_location: reps } }.to_json

    expect(body['notices']).to eq([])
    expect(PlayInstallation.active.exists?(company_id: company.id, play_key: 'weekly_homes_email')).to be false
  end

  it 'hides a play that is off, lists it only when asked, and shows it again' do
    post '/api/v1/plays/deal_to_sold/dismiss', headers: headers
    expect(response).to have_http_status(:ok)
    expect(body.dig('play', 'dismissed')).to be true

    expect(listed_keys).not_to include('deal_to_sold')
    expect(listed_keys('?include_dismissed=true')).to include('deal_to_sold')

    post '/api/v1/plays/deal_to_sold/restore', headers: headers
    expect(body.dig('play', 'dismissed')).to be false
    expect(listed_keys).to include('deal_to_sold')
  end

  it 'will not hide a play that is on, and turning off with remove hides it and deletes its page' do
    post '/api/v1/plays/walk_in_visit/install', headers: headers, params: { answers: { reps_by_location: reps } }.to_json
    post '/api/v1/plays/walk_in_visit/dismiss', headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body['error']).to eq('Turn Walk-in visit off before hiding it.')

    company.tenant_module_overrides.create!(module_key: 'marketing.landing_pages', is_enabled: true)
    installation = Plays::PromoLandingPage.new(company: company, user: user, answers: {}).install!
    page = Plays::PromoLandingPage.page_for(installation)

    post '/api/v1/plays/promo_landing_page/uninstall', headers: headers, params: { remove: true }.to_json

    expect(response).to have_http_status(:ok)
    expect(page.reload).to have_attributes(is_deleted: true, published_at: nil)
    expect(listed_keys).not_to include('promo_landing_page')

    # Turning it back on brings it back to the list.
    post '/api/v1/plays/promo_landing_page/restore', headers: headers
    post '/api/v1/plays/promo_landing_page/install', headers: headers, params: { answers: {} }.to_json
    expect(response).to have_http_status(:created)
    expect(listed_keys).to include('promo_landing_page')
  end
end
