# frozen_string_literal: true

require 'rails_helper'

# What the Help panel records for each outcome (E118).
RSpec.describe 'Help assistant outcomes', type: :request do
  include ActiveJob::TestHelper

  let(:company) { create(:company, use_rbac_system: false) }
  let(:user) do
    User.create!(email: "ask-#{SecureRandom.hex(4)}@example.com", password: 'Password123!',
                 company: company, first_name: 'Ask', last_name: 'Er', status: 'active')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" } }

  before { Setting.set('Company', company.id, 'ai_report_queries_monthly_limit', 5) }

  def reply_with(input)
    fake = Class.new do
      define_method(:call) do |**|
        { 'content' => [{ 'type' => 'tool_use', 'id' => 't1', 'name' => 'reply', 'input' => input }],
          'usage' => { 'input_tokens' => 100, 'output_tokens' => 20 } }
      end
    end.new
    allow(Guide::ClaudeChat).to receive(:new).and_return(fake)
  end

  def ask(question = 'Tax disappears when I save deal 659')
    post '/api/v1/guide/assistant', params: { question: question, page: '/deals/659' }, headers: headers
    response.parsed_body
  end

  it 'hands something that looks wrong to support, with the exchange' do
    reply_with('answer_markdown' => 'x', 'outcome' => 'looks_wrong', 'assistant_reason' => 'Tax drops on save')
    body = nil
    expect { body = ask }.to change(GuideFlag, :count).by(1).and have_enqueued_mail(GuideFlagMailer, :flagged)
    flag = GuideFlag.last
    expect(body['outcome']).to eq('looks_wrong')
    expect(body['answer']).to eq(Guide::Assistant::FIXED_ANSWERS['looks_wrong'])
    expect(flag.kind).to eq('looks_wrong')
    expect(flag.page).to eq('/deals/659')
    expect(flag.assistant_reason).to eq('Tax drops on save')
    expect(flag.guide_conversation_id).to eq(body['conversation_id'])
    expect(Knowledge::Search.where(result_count: 0)).to be_empty
  end

  it 'does not count a clarifying question as a gap in the help' do
    reply_with('answer_markdown' => 'Which deal do you mean?', 'outcome' => 'needs_detail')
    expect { ask('why is tax missing') }.not_to change(GuideFlag, :count)
    expect(Knowledge::Search.where(result_count: 0)).to be_empty
  end

  it 'logs a question the help does not cover as a gap' do
    reply_with('answer_markdown' => 'I do not know that one.', 'outcome' => 'no_help')
    ask('how do I frobnicate')
    expect(Knowledge::Search.where(result_count: 0, query: 'how do I frobnicate')).to exist
  end

  it 'records which lookups ran and what caching saved' do
    reply_with('answer_markdown' => 'Open Settings.', 'outcome' => 'answered')
    ask('where are settings')
    log = AiQueryLog.where(feature: 'help_assistant').last
    expect(log.generated_params['outcome']).to eq('answered')
  end

  it 'lets platform admins list and close flags' do
    reply_with('answer_markdown' => 'x', 'outcome' => 'needs_support', 'assistant_reason' => 'Move homes to Main')
    ask('please move our homes to Main')
    admin = User.create!(email: "pa-#{SecureRandom.hex(3)}@example.com", password: 'Password123!', company: company,
                         first_name: 'Plat', last_name: 'Form', status: 'active', role: 'super_admin')
    admin_headers = { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: admin.id, company_id: company.id)}" }
    get '/api/admin/guide/flags', headers: admin_headers
    expect(response).to have_http_status(:ok)
    flag = response.parsed_body['flags'].first
    expect(flag['kind']).to eq('request')

    patch "/api/admin/guide/flags/#{flag['id']}", params: { status: 'done', notes: 'Moved 2 homes' }, headers: admin_headers
    expect(GuideFlag.find(flag['id'])).to have_attributes(status: 'done', notes: 'Moved 2 homes')

    get '/api/admin/guide/flags', headers: headers
    expect(response).to have_http_status(:forbidden)
  end
end
