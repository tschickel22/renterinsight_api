# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'GET /o/r/:token website checkup', type: :request do
  let(:company) { Company.create!(name: "DealerTide Test #{SecureRandom.hex(3)}") }
  let(:tom) do
    User.create!(email: "t-#{SecureRandom.hex(4)}@example.com", first_name: 'Tom', last_name: 'S', password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin', status: 'active')
  end
  let(:lead) { company.leads.create!(first_name: 'A', last_name: 'L', email: 'a@sunrisebiloxi.com', owner_id: tom.id, status: 'new') }
  let(:wave) { company.outreach_waves.create!(name: 'W', status: 'running') }
  let(:target) do
    wave.outreach_targets.create!(company_id: company.id, lead_id: lead.id, channel: 'email', site_research: {
      'status' => 'found', 'url' => 'https://www.sunrisebiloxi.com',
      'report' => { 'score' => 54, 'pages_checked' => 4, 'passed' => 9, 'meaning' => 'In practice, buyers may not find this dealership.',
                    'areas' => [{ 'label' => 'Homes marked up for search', 'status' => 'fail', 'affected_count' => 3,
                                  'consequence' => 'individual homes are not described in a form search engines can read' }] }
    })
  end

  before { Outreach::Settings.for(company).update!('persona_name' => 'Tom Schickel') }

  it 'shows the score, areas and what they cost, offers the full report by reply, and counts the view once' do
    token = Outreach::Tracking.report_url(target).split('/o/r/').last
    get "/o/r/#{token}", headers: { 'User-Agent' => 'Mozilla/5.0' }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('sunrisebiloxi.com', '54', 'Homes marked up for search', '3 pages', 'Individual homes are not described',
                                     'reply to my message', 'Tom Schickel')
    get "/o/r/#{token}", headers: { 'User-Agent' => 'Mozilla/5.0' }
    expect(OutreachEvent.where(outreach_target_id: target.id, event_type: 'report_viewed').count).to eq(1)
  end

  it 'refuses a forged token or another purpose' do
    get '/o/r/forged'
    expect(response).to have_http_status(:not_found)
    unsubscribe_token = Outreach::Tracking.unsubscribe_url(target).split('/o/u/').last
    get "/o/r/#{unsubscribe_token}"
    expect(response).to have_http_status(:not_found)
  end
end
