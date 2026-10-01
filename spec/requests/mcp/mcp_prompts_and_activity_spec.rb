# frozen_string_literal: true

require 'rails_helper'
require_relative '../../support/mcp_connector_helpers'

# The cookbook prompts, ChatGPT's per-tool auth declaration, and the
# oversight screen an admin uses to see what the AI apps did.
RSpec.describe 'MCP prompts and AI activity', :mcp, type: :request do
  before { seed_rbac! }

  let(:company) { connector_company }
  let(:user) { connector_user(company, { 'leads' => %w[read] }) }
  let(:token) { connect!(user)['access_token'] }

  describe 'prompts' do
    it 'lists the cookbook and fills in arguments' do
      names = mcp_post(token, 'prompts/list').dig('result', 'prompts').map { |p| p['name'] }
      expect(names).to include('morning_briefing', 'lead_triage', 'aging_inventory', 'stalled_deals',
                               'customer_follow_up', 'service_backlog')

      body = mcp_post(token, 'prompts/get', { name: 'aging_inventory', arguments: { min_days: '120' } })
      text = body.dig('result', 'messages', 0, 'content', 'text')
      expect(text).to include('at least 120 days')
    end

    it 'asks for the customer when the follow-up prompt has none' do
      body = mcp_post(token, 'prompts/get', { name: 'customer_follow_up', arguments: {} })
      expect(body['error']['message']).to include('customer')
    end

    it 'tells the AI not to use dashes in anything it drafts for a customer, and uses none itself' do
      McpController::PROMPTS.each do |prompt|
        text = prompt.text_for(customer: 'Ana Diaz')
        expect(text).not_to match(/[\u2013\u2014]/), prompt.name
      end
      %w[lead_triage aging_inventory customer_follow_up].each do |name|
        prompt = McpController::PROMPTS.find { |p| p.name_value == name }
        expect(prompt.text_for(customer: 'x')).to include('never use em dashes')
      end
    end
  end

  it 'declares the OAuth scope each tool needs, for ChatGPT' do
    tools = mcp_post(token, 'tools/list').dig('result', 'tools')
    search = tools.find { |t| t['name'] == 'search' }
    create = tools.find { |t| t['name'] == 'create_lead' }

    expect(search.dig('_meta', 'securitySchemes')).to eq([{ 'type' => 'oauth2', 'scopes' => ['mcp:read'] }])
    expect(create.dig('_meta', 'securitySchemes')).to eq([{ 'type' => 'oauth2', 'scopes' => ['mcp:write'] }])
  end

  describe 'activity and limits for admins' do
    let(:admin) { connector_user(company, {}, role: 'company_admin') }

    before do
      company.leads.create!(first_name: 'A', last_name: 'B', email: 'ab@example.com', status: 'new')
      call_tool(token, 'list_leads')
      call_tool(token, 'list_deals')
    end

    it "shows an admin every user's calls, and a user only their own" do
      get '/api/v1/connected-apps/activity', headers: app_headers(admin)
      body = response.parsed_body
      expect(body['calls'].map { |c| c['tool'] }).to eq(%w[list_deals list_leads])
      expect(body['calls'].first).to include('user' => user.full_name, 'app' => 'Claude', 'status' => 'denied')
      expect(body['today']).to include('calls' => 2, 'records' => 1, 'denied' => 1)

      other = connector_user(company, { 'leads' => %w[read] })
      get '/api/v1/connected-apps/activity', headers: app_headers(other)
      expect(response.parsed_body['calls']).to be_empty
    end

    it 'lets an admin set the daily record limit, and the tools obey it' do
      put '/api/v1/connected-apps/settings', params: { daily_record_limit: 1 }, headers: app_headers(admin)
      expect(response).to have_http_status(:ok)

      _r, is_error, text = call_tool(token, 'list_leads')
      expect(is_error).to be(true)
      expect(text).to include('Daily limit of 1 records')
    end

    it 'refuses the limit change from a user without settings access, and nonsense values' do
      put '/api/v1/connected-apps/settings', params: { daily_record_limit: 5 }, headers: app_headers(user)
      expect(response).to have_http_status(:forbidden)

      put '/api/v1/connected-apps/settings', params: { daily_record_limit: 'lots' }, headers: app_headers(admin)
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end
end
