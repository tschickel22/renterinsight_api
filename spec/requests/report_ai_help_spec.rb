# frozen_string_literal: true

require 'rails_helper'

# The AI Assistant (header sparkle) hands how-to questions to the help
# assistant (backlog E75), and the question counts once, not twice.
RSpec.describe 'AI Assistant how-to questions', type: :request do
  let(:company) { create(:company, use_rbac_system: false) }
  let(:user) do
    User.create!(email: "ai-help-#{SecureRandom.hex(4)}@example.com", password: 'Password123!',
                 company: company, first_name: 'Ai', last_name: 'Help')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" } }
  let(:help) do
    Guide::Assistant::Result.new(answer: 'Open Settings, then Users.', articles: [{ slug: 'add-a-user', title: 'Add a user' }],
                                 places: [{ key: 'setting:users', title: 'Users' }], answered: true,
                                 input_tokens: 1000, output_tokens: 200)
  end

  def classified(intent)
    { intent: intent, action: intent == 'help' ? 'help_answer' : 'unknown', requires_confirmation: intent != 'help',
      explanation: '', params: {}, input_tokens: 50, output_tokens: 10, cost_cents: 1, response_time_ms: 5 }
  end

  before do
    Setting.set('Company', company.id, 'ai_report_queries_monthly_limit', 50)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('ANTHROPIC_API_KEY').and_return('test-key')
    assistant = instance_double(Guide::Assistant, ask: help)
    allow(Guide::Assistant).to receive(:new).and_return(assistant)
  end

  %w[help unknown].each do |intent|
    it "answers a #{intent} question from the help, as one use" do
      allow_any_instance_of(AiActionService).to receive(:classify).and_return(classified(intent))

      expect do
        post '/api/v1/report-ai/classify', params: { question: 'how do I add a user' }, headers: headers
      end.to change(AiQueryLog, :count).by(1)

      body = JSON.parse(response.body)
      expect(body).to include('intent' => 'help', 'requires_confirmation' => false)
      expect(body['help']).to include('answer' => 'Open Settings, then Users.', 'answered' => true)
      expect(AiQueryLog.last).to have_attributes(feature: 'report_ai', resolved_intent: 'help', execution_status: 'success',
                                                 input_tokens: 1050, output_tokens: 210)
    end
  end

  it 'says the help could not be reached rather than going quiet' do
    allow(Guide::Assistant).to receive(:new).and_return(instance_double(Guide::Assistant).tap { |a| allow(a).to receive(:ask).and_raise(Guide::ClaudeChat::Error, 'overloaded') })
    allow_any_instance_of(AiActionService).to receive(:classify).and_return(classified('help'))

    post '/api/v1/report-ai/classify', params: { question: 'how do I add a user' }, headers: headers

    body = JSON.parse(response.body)
    expect(body['intent']).to eq('help')
    expect(body['help']).to include('answered' => false)
    expect(body['help']['answer']).to include('could not reach the help')
    expect(AiQueryLog.last).to have_attributes(execution_status: 'error', failure_reason: 'help_unavailable')
  end

  it 'falls back to the classifier for an unknown question when the help fails' do
    allow(Guide::Assistant).to receive(:new).and_return(instance_double(Guide::Assistant).tap { |a| allow(a).to receive(:ask).and_raise(Guide::ClaudeChat::Error, 'overloaded') })
    allow_any_instance_of(AiActionService).to receive(:classify).and_return(classified('unknown'))

    post '/api/v1/report-ai/classify', params: { question: 'zzz' }, headers: headers

    expect(JSON.parse(response.body)).to include('intent' => 'unknown', 'help' => nil)
  end

  it 'leaves data questions to the report engine' do
    allow_any_instance_of(AiActionService).to receive(:classify).and_return(classified('read').merge(action: 'report_query'))

    post '/api/v1/report-ai/classify', params: { question: 'how many leads this week' }, headers: headers

    expect(JSON.parse(response.body)).to include('intent' => 'read', 'help' => nil)
    expect(Guide::Assistant).not_to have_received(:new)
  end
end
