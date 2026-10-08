# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Campaign SMS availability and mixed-campaign consent', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:token) { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }

  describe 'GET /api/v1/campaigns/sms_status' do
    it 'reports no number' do
      get '/api/v1/campaigns/sms_status', headers: headers
      expect(JSON.parse(response.body)).to include('available' => false)
    end

    it 'reports the company number' do
      TwilioAccount.create!(company_id: company.id, phone_number: '+15558889999', phone_number_sid: 'PN1', status: 'active')
      get '/api/v1/campaigns/sms_status', headers: headers
      expect(JSON.parse(response.body)).to include('available' => true, 'from_number' => '+15558889999')
    end
  end

  it 'refuses an SMS draft from the AI builder without a number' do
    post '/api/v1/campaigns/ai_generate', params: { prompt: 'text my leads', channel: 'mixed' }.to_json, headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
    expect(JSON.parse(response.body)['error']).to match(/No active SMS number/)
  end

  it 'previews the first email step of a mixed plan that opens with a text' do
    gen = CampaignAiGeneration.create!(
      company: company, user: user, prompt: 'p', status: 'generated',
      generated_plan: { 'channel' => 'mixed', 'name' => 'M', 'steps' => [
        { 'channel' => 'sms', 'sms_body' => 'Hi' },
        { 'channel' => 'email', 'subject' => 'The email', 'body_blocks' => [{ 'type' => 'text', 'html' => '<p>x</p>' }] }
      ] }
    )
    get "/api/v1/campaigns/ai_generate/#{gen.id}/preview_render", headers: headers
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)['subject']).to eq('The email')
  end

  it 'accepts the consent override on an email campaign with an SMS step' do
    c = Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'Mixed',
                         campaign_type: 'drip', channel: 'email',
                         from_identity_type: 'User', from_identity_id: user.id, throttle_per_day: 100)
    c.campaign_steps.create!(position: 0, channel: 'email', subject: 'Hi', body_blocks: [{ 'type' => 'text', 'html' => 'x' }])
    c.campaign_steps.create!(position: 1, channel: 'sms', sms_body: 'Hi')
    c.create_campaign_audience!(source_type: 'Lead', filter_tree: {})

    post "/api/v1/campaigns/#{c.id}/audience/acknowledge_sms_compliance",
         params: { acknowledgment: 'I have written consent from every recipient' }.to_json, headers: headers
    expect(response).to have_http_status(:ok)
    expect(c.campaign_audience.reload.sms_compliance_override?).to be true
  end
end
