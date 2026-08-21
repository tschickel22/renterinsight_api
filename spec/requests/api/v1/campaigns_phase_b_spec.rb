# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::Campaigns Phase B endpoints', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(3)}@example.com",
                 first_name: 'T', last_name: 'U', password: 'Pass1234!',
                 company_id: company.id, role: 'platform_admin')
  end
  let(:token) { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }

  let(:campaign) do
    c = Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'C',
                         campaign_type: 'blast', from_identity_type: 'User', from_identity_id: user.id,
                         throttle_per_day: 100)
    c.campaign_steps.create!(position: 0, channel: 'email', subject: 'Hi {{first_name}}',
                              body_blocks: [{ 'type' => 'text', 'html' => 'Hi {{first_name}}' }])
    c
  end

  describe 'GET /api/v1/campaigns/:id/preview' do
    it 'renders email subject and body with merge tags using a fake recipient' do
      get "/api/v1/campaigns/#{campaign.id}/preview", headers: headers
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['channel']).to eq('email')
      expect(body['subject']).to eq('Hi Sample')
      expect(body['html_body']).to include('Hi Sample')
      expect(body['step_position']).to eq(1)
    end

    it 'previews the step named by step_id, not always the first one' do
      second = campaign.campaign_steps.create!(position: 1, channel: 'email', subject: 'Second step',
                                               body_blocks: [{ 'type' => 'text', 'html' => 'Body two' }])

      get "/api/v1/campaigns/#{campaign.id}/preview", params: { step_id: second.id }, headers: headers
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['step_id']).to eq(second.id)
      expect(body['step_position']).to eq(2)
      expect(body['subject']).to eq('Second step')
      expect(body['html_body']).to include('Body two')
    end

    it 'returns 422 when step_id belongs to another campaign' do
      other = Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'Other',
                               campaign_type: 'blast', from_identity_type: 'User', from_identity_id: user.id,
                               throttle_per_day: 100)
      foreign_step = other.campaign_steps.create!(position: 0, channel: 'email', subject: 'Nope',
                                                  body_blocks: [])

      get "/api/v1/campaigns/#{campaign.id}/preview", params: { step_id: foreign_step.id }, headers: headers
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe 'POST /api/v1/campaigns/:id/test_send' do
    it 'returns 422 when no email connection is configured for the user' do
      post "/api/v1/campaigns/#{campaign.id}/test_send", headers: headers
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe 'POST /api/v1/campaigns/ai_generate' do
    it 'requires a prompt' do
      post '/api/v1/campaigns/ai_generate', headers: headers, params: {}.to_json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['error']).to match(/prompt/i)
    end

    it 'returns generation_id and plan when AiBuilder succeeds' do
      generation = CampaignAiGeneration.create!(company: company, user: user, prompt: 'p',
                                                 generated_plan: { 'name' => 'X' }, status: 'generated',
                                                 model_version: 'claude-test', input_tokens: 1, output_tokens: 1)
      builder = instance_double(Campaigns::AiBuilder, generate: generation)
      allow(Campaigns::AiBuilder).to receive(:new).and_return(builder)

      post '/api/v1/campaigns/ai_generate', headers: headers, params: { prompt: 'B2B drip' }.to_json
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['generation_id']).to eq(generation.id)
      expect(body['plan']['name']).to eq('X')
    end

    it 'returns 429 on credit limit error' do
      builder = instance_double(Campaigns::AiBuilder)
      allow(builder).to receive(:generate).and_raise(Campaigns::AiBuilder::CreditLimitError.new('over'))
      allow(Campaigns::AiBuilder).to receive(:new).and_return(builder)

      post '/api/v1/campaigns/ai_generate', headers: headers, params: { prompt: 'X' }.to_json
      expect(response).to have_http_status(:too_many_requests)
      expect(JSON.parse(response.body)['code']).to eq('credit_limit')
    end
  end

  describe 'POST /api/v1/campaigns/ai_generate/:generation_id/accept' do
    it 'returns 404 for unknown generation' do
      post '/api/v1/campaigns/ai_generate/9999999/accept', headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it 'creates a Campaign from a generation plan' do
      plan = {
        'name' => 'AI Created', 'channel' => 'email', 'campaign_type' => 'drip',
        'steps' => [{ 'wait_days' => 0, 'subject' => 'Hi', 'body_blocks' => [{ 'type' => 'text', 'html' => 'a' }] }],
        'audience' => { 'source_type' => 'Lead', 'filter_tree' => {} },
        'goal_config' => { 'primary_goal' => 'replied' }, 'send_window' => {}
      }
      generation = CampaignAiGeneration.create!(company: company, user: user, prompt: 'p',
                                                 generated_plan: plan, status: 'generated')

      post "/api/v1/campaigns/ai_generate/#{generation.id}/accept", headers: headers, params: {}.to_json
      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body['name']).to eq('AI Created')
      expect(generation.reload.status).to eq('accepted')
    end
  end

  describe 'POST /api/v1/campaigns/ai_generate/:generation_id/refine' do
    it 'returns 422 when feedback is missing' do
      generation = CampaignAiGeneration.create!(company: company, user: user, prompt: 'p',
                                                 generated_plan: { 'channel' => 'email' }, status: 'generated')
      post "/api/v1/campaigns/ai_generate/#{generation.id}/refine", headers: headers, params: {}.to_json
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end
end
