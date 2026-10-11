# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Help assistant', type: :request do
  let(:company) { create(:company, use_rbac_system: false) }
  let(:user) do
    User.create!(email: "ask-#{SecureRandom.hex(4)}@example.com", password: 'Password123!',
                 company: company, first_name: 'Ask', last_name: 'Er', status: 'active')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" } }

  let!(:article) do
    Knowledge::Article.create!(title: 'Run a Profit & Loss report', slug: 'run-pnl', is_published: true,
                               content: 'Open Reports, then Profit & Loss. Pick the dates.')
  end

  before do
    Knowledge::Snapshot.create!(
      source: 'frontend', snapshot_at: Time.current, modules_hash: 'x',
      atlas: { 'entries' => [
        { 'key' => 'report:profit-and-loss', 'kind' => 'report', 'title' => 'Profit & Loss', 'route' => '/accounting/reports/profit-and-loss',
          'breadcrumb' => ['Reports', 'Financial Statements'], 'synonyms' => ['p and l', 'income statement'],
          'where' => [{ 'text' => 'Click Reports.' }], 'requires' => [{ 'reportResource' => 'financial_reports' }] },
        { 'key' => 'page:/admin', 'kind' => 'page', 'title' => 'Platform Admin', 'route' => '/admin',
          'breadcrumb' => [], 'synonyms' => [], 'where' => [], 'requires' => [{ 'adminOnly' => true }] }
      ] }
    )
    Setting.set('Company', company.id, 'ai_report_queries_monthly_limit', 5)
    allow(Guide::ClaudeChat).to receive(:new).and_return(fake_claude)
  end

  # Plays the part of Claude: looks up a place and an article, then replies,
  # citing one real slug and key and one made up of each.
  let(:fake_claude) do
    Class.new do
      attr_reader :calls

      def initialize
        @calls = []
      end

      def call(messages:, **)
        @calls << messages
        usage = { 'input_tokens' => 1000, 'output_tokens' => 200 }
        if @calls.size == 1
          { 'content' => [
            { 'type' => 'tool_use', 'id' => 't1', 'name' => 'find_place', 'input' => { 'query' => 'profit loss report' } },
            { 'type' => 'tool_use', 'id' => 't2', 'name' => 'search_help', 'input' => { 'query' => 'profit loss report' } },
            { 'type' => 'tool_use', 'id' => 't3', 'name' => 'find_place', 'input' => { 'query' => 'platform admin' } }
          ], 'usage' => usage }
        else
          { 'content' => [{ 'type' => 'tool_use', 'id' => 't4', 'name' => 'reply', 'input' => {
            'answer_markdown' => "Open Reports — then Profit & Loss.",
            'article_slugs' => %w[run-pnl invented-slug], 'place_keys' => %w[report:profit-and-loss page:/admin], 'answered' => true
          } }], 'usage' => usage }
        end
      end
    end.new
  end

  def ask(question, extra = {})
    post '/api/v1/guide/assistant', params: { question: question }.merge(extra), headers: headers, as: :json
    JSON.parse(response.body)
  end

  it 'answers from the tools and links only what the tools returned and the person can open' do
    body = ask('where is the P&L report')

    expect(body['answer']).to eq('Open Reports, then Profit & Loss.')
    expect(body['articles'].map { |a| a['slug'] }).to eq(['run-pnl'])
    expect(body['places'].map { |p| p['key'] }).to eq(['report:profit-and-loss'])
    # The admin-only page was never offered to the model's tool results.
    tool_results = fake_claude.calls.last.last[:content].map { |c| c[:content] }.join
    expect(tool_results).not_to include('page:/admin')
  end

  it 'counts toward the shared monthly AI allowance and keeps the thread' do
    first = ask('where is the P&L report')
    expect(first['remaining']).to eq(4)
    expect(AiQueryLog.monthly_used_for(company)).to eq(1)

    ask('and the balance sheet?', conversation_id: first['conversation_id'])
    expect(GuideConversation.find(first['conversation_id']).messages.size).to eq(4)
  end

  it 'stops when the allowance is used up, without calling Claude' do
    Setting.set('Company', company.id, 'ai_report_queries_monthly_limit', 1)
    ask('one')
    body = ask('two')

    expect(body).to include('limited' => true, 'remaining' => 0)
    expect(fake_claude.calls.size).to eq(2) # both rounds of the first question only
  end

  it 'logs unanswered questions as gaps to write help for' do
    allow(fake_claude).to receive(:call).and_return(
      { 'content' => [{ 'type' => 'tool_use', 'id' => 'x', 'name' => 'reply',
                        'input' => { 'answer_markdown' => 'I do not know.', 'answered' => false } }], 'usage' => {} }
    )
    ask('how do I file a FEMA claim')

    expect(Knowledge::Search.last).to have_attributes(query: 'how do I file a FEMA claim', result_count: 0, action_taken: 'assistant')
    expect(AiQueryLog.last.resolved_intent).to eq('unanswered')
  end

  it 'gives a company without the AI add-on 50 help questions a month, help only' do
    Setting.set('Company', company.id, 'ai_report_queries_monthly_limit', 0)
    allow(AiQueryLog).to receive(:monthly_limit_for).and_return(0)
    3.times { AiQueryLog.create!(company: company, feature: 'report_ai', execution_status: 'success') }

    get '/api/v1/guide/assistant', headers: headers
    expect(JSON.parse(response.body)).to include('enabled' => true, 'limit' => 50, 'remaining' => 50, 'pool' => 'help_only')

    body = ask('where is the P&L report')
    expect(body['remaining']).to eq(49)
  end

  it 'reports whether it is available' do
    get '/api/v1/guide/assistant', headers: headers
    expect(JSON.parse(response.body)).to include('enabled' => true, 'remaining' => 5)
  end
end
