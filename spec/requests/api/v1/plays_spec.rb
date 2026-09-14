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
  let(:reps) { { location.id.to_s => [rep.id] } }

  before do
    allow(Plays::LeadResponsePlay).to receive(:texting_ready?).and_return(false)
  end

  def body
    JSON.parse(response.body)
  end

  it 'lists the per-channel plays, each with a map of what it does' do
    get '/api/v1/plays', headers: headers

    expect(response).to have_http_status(:ok)
    keys = body['plays'].map { |p| p['key'] }
    expect(keys).to contain_exactly('new_facebook_lead', 'walk_in_visit', 'promo_landing_page', 'weekly_homes_email', 'deal_to_sold')
    expect(body['plays'].to_h { |p| [p['key'], p['kind']] })
      .to eq('new_facebook_lead' => 'lead_response', 'walk_in_visit' => 'lead_response',
             'promo_landing_page' => 'landing_page', 'weekly_homes_email' => 'recurring_email',
             'deal_to_sold' => 'deal_followup')
    facebook = body['plays'].find { |p| p['key'] == 'new_facebook_lead' }
    expect(facebook['map'].map { |s| s['key'] }).to include('trigger', 'first_email', 'reply_wait')
    expect(facebook['installation']).to be_nil
  end

  it 'turns a play on and returns its forms and map' do
    post '/api/v1/plays/new_facebook_lead/install', headers: headers,
                                                     params: { answers: { reps_by_location: reps } }.to_json

    expect(response).to have_http_status(:created)
    installation = body.dig('play', 'installation')
    expect(installation['sources']).to eq(['Facebook'])
    expect(installation['send_texts']).to be false
    expect(installation['intake_forms'].first).to include('name' => 'Facebook Contact', 'source' => 'Facebook')
    expect(installation['map'].first['title']).to eq('New lead from Facebook')
  end

  it 'saves customized content' do
    post '/api/v1/plays/new_facebook_lead/install', headers: headers,
                                                     params: { answers: { reps_by_location: reps } }.to_json
    content = body.dig('play', 'installation', 'content')
    content['call_task']['due_minutes'] = 5

    patch '/api/v1/plays/new_facebook_lead/customize', headers: headers,
                                                        params: { answers: { reps_by_location: reps, content: content } }.to_json

    expect(response).to have_http_status(:ok)
    expect(body.dig('play', 'installation', 'content', 'call_task', 'due_minutes')).to eq(5)
  end

  it 'explains a customization it cannot save' do
    post '/api/v1/plays/new_facebook_lead/install', headers: headers,
                                                     params: { answers: { reps_by_location: reps } }.to_json
    content = body.dig('play', 'installation', 'content')
    content['reply_wait_hours'] = 0

    patch '/api/v1/plays/new_facebook_lead/customize', headers: headers,
                                                        params: { answers: { reps_by_location: reps, content: content } }.to_json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(body['error']).to eq('Wait between 1 and 168 hours for a reply.')
  end

  it 'shows a retired play only while this company still has it on, and turns it off' do
    PlayInstallation.create!(company_id: company.id, play_key: 'new_lead_any_channel', status: 'active',
                             answers: { 'channels' => ['google'] }, assets: {}, installed_at: Time.current)

    get '/api/v1/plays', headers: headers
    expect(body['plays'].map { |p| p['key'] }).to include('new_lead_any_channel')

    post '/api/v1/plays/new_lead_any_channel/uninstall', headers: headers
    expect(response).to have_http_status(:ok)

    get '/api/v1/plays', headers: headers
    expect(body['plays'].map { |p| p['key'] }).not_to include('new_lead_any_channel')
  end
end
