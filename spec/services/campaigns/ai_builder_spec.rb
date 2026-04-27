# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Campaigns::AiBuilder do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:user)    { User.create!(email: "u-#{SecureRandom.hex(3)}@example.com", first_name: 'T', last_name: 'U', password: 'Pass1234!', company_id: company.id) }

  before { allow(ENV).to receive(:[]).and_call_original }

  def stub_claude_response(plan, input_tokens: 1000, output_tokens: 500, status: '200')
    body = {
      'content' => [{ 'type' => 'text', 'text' => plan.to_json }],
      'usage' => { 'input_tokens' => input_tokens, 'output_tokens' => output_tokens }
    }.to_json
    response = instance_double(Net::HTTPResponse, code: status, body: body)
    allow(response).to receive(:[]).with('Content-Type').and_return('application/json')
    http = instance_double(Net::HTTP)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:request).and_return(response)
    allow(Net::HTTP).to receive(:new).and_return(http)
    allow(ENV).to receive(:[]).with('ANTHROPIC_API_KEY').and_return('test-key')
  end

  describe '#generate' do
    let(:plan) { { 'name' => 'Test Plan', 'channel' => 'email', 'campaign_type' => 'drip', 'steps' => [{ 'wait_days' => 0, 'subject' => 'Hi', 'body_blocks' => [] }], 'audience' => { 'source_type' => 'Lead', 'filter_tree' => {} }, 'goal_config' => { 'primary_goal' => 'replied' } } }

    it 'creates a CampaignAiGeneration with parsed plan' do
      stub_claude_response(plan)
      gen = described_class.new(company: company, user: user).generate(prompt: 'Build me a B2B drip campaign', channel: 'email')
      expect(gen).to be_a(CampaignAiGeneration)
      expect(gen.generated_plan['name']).to eq('Test Plan')
      expect(gen.input_tokens).to eq(1000)
      expect(gen.output_tokens).to eq(500)
    end

    it 'logs to AiQueryLog with cost in cents' do
      stub_claude_response(plan)
      expect {
        described_class.new(company: company, user: user).generate(prompt: 'X', channel: 'email')
      }.to change { AiQueryLog.where(feature: 'ai_campaign_generate').count }.by(1)
      log = AiQueryLog.where(feature: 'ai_campaign_generate').last
      expect(log.cost_cents).to be > 0
      expect(log.module_key).to eq('campaigns')
    end

    it 'raises GenerationError when API returns non-200' do
      stub_claude_response(plan, status: '500')
      expect {
        described_class.new(company: company, user: user).generate(prompt: 'X')
      }.to raise_error(described_class::GenerationError, /Claude API error/)
    end

    it 'raises GenerationError on invalid JSON' do
      body = { 'content' => [{ 'type' => 'text', 'text' => 'this is not json' }], 'usage' => {} }.to_json
      response = instance_double(Net::HTTPResponse, code: '200', body: body)
      http = instance_double(Net::HTTP)
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:read_timeout=)
      allow(http).to receive(:open_timeout=)
      allow(http).to receive(:request).and_return(response)
      allow(Net::HTTP).to receive(:new).and_return(http)
      allow(ENV).to receive(:[]).with('ANTHROPIC_API_KEY').and_return('test-key')
      expect {
        described_class.new(company: company, user: user).generate(prompt: 'X')
      }.to raise_error(described_class::GenerationError, /invalid JSON/)
    end

    it 'raises CreditLimitError when monthly cap reached' do
      allow(ENV).to receive(:[]).with('AI_CAMPAIGN_MONTHLY_CREDIT').and_return('1')
      allow(ENV).to receive(:[]).with('ANTHROPIC_API_KEY').and_return('test-key')
      AiQueryLog.create!(company: company, user: user, feature: 'ai_campaign_generate',
                         module_key: 'campaigns', execution_status: 'success')
      expect {
        described_class.new(company: company, user: user).generate(prompt: 'X')
      }.to raise_error(described_class::CreditLimitError)
    end
  end

  describe '#accept' do
    let(:plan) do
      {
        'name' => 'My Campaign', 'channel' => 'email', 'campaign_type' => 'drip',
        'steps' => [{ 'wait_days' => 0, 'subject' => 'Hi', 'body_blocks' => [{ 'type' => 'text', 'html' => 'x' }] }],
        'audience' => { 'source_type' => 'Lead', 'filter_tree' => {} },
        'goal_config' => { 'primary_goal' => 'replied' },
        'send_window' => {}
      }
    end

    it 'creates a Campaign + steps + audience and marks generation accepted' do
      generation = CampaignAiGeneration.create!(company: company, user: user, prompt: 'p',
                                                 generated_plan: plan, status: 'generated')
      campaign = described_class.new(company: company, user: user).accept(
        generation: generation,
        sender_params: { from_identity_type: 'User', from_identity_id: user.id }
      )
      expect(campaign).to be_persisted
      expect(campaign.campaign_steps.count).to eq(1)
      expect(campaign.campaign_audience).not_to be_nil
      expect(generation.reload.status).to eq('accepted')
      expect(generation.campaign_id).to eq(campaign.id)
    end
  end

  describe '#refine' do
    let(:plan) { { 'name' => 'V2', 'channel' => 'email', 'campaign_type' => 'drip', 'steps' => [], 'audience' => {} } }

    it 'creates a child generation linked via parent_generation_id' do
      stub_claude_response(plan)
      parent = CampaignAiGeneration.create!(company: company, user: user, prompt: 'p',
                                             generated_plan: { 'channel' => 'email' }, status: 'generated')
      child = described_class.new(company: company, user: user).refine(generation: parent, feedback: 'shorter')
      expect(child.parent_generation_id).to eq(parent.id)
      expect(child.status).to eq('refined')
    end
  end
end
