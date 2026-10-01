# frozen_string_literal: true

require 'rails_helper'
require_relative '../../support/mcp_connector_helpers'

# Oversight for the AI connector: company admins hear the same day when a
# person's AI app hits the record limit or keeps getting refused, and the
# platform operator can see which dealers use it and how much.
RSpec.describe 'MCP alerts and platform usage', :mcp, type: :request do
  before { seed_rbac! }

  let(:company) { connector_company }
  let(:user) { connector_user(company, { 'leads' => %w[read] }) }
  let!(:admin) { connector_user(company, {}, role: 'company_admin') }
  let(:token) { connect!(user)['access_token'] }

  def alerts
    Notification.where(company_id: company.id, notification_type: 'ai_connector_alert')
  end

  describe 'admin alerts' do
    it 'tells the company admins once when a person hits the daily record limit' do
      2.times { |i| company.leads.create!(first_name: "L#{i}", last_name: 'X', email: "l#{i}@example.com", status: 'new') }
      Setting.set('Company', company.id, 'mcp_settings', { 'daily_record_limit' => 2 })

      call_tool(token, 'list_leads')
      expect(alerts).to be_empty

      3.times { call_tool(token, 'list_leads') }

      expect(alerts.count).to eq(1)
      expect(alerts.first).to have_attributes(recipient_id: admin.id, action_url: '/settings?tab=ai-apps')
      expect(alerts.first.message).to include(user.full_name, 'daily limit of 2 records')
    end

    it 'tells them when an AI app keeps being refused, but not for a single refusal' do
      call_tool(token, 'list_deals')
      expect(alerts).to be_empty

      (McpTools::Alerts::REFUSALS_PER_HOUR - 1).times { call_tool(token, 'list_deals') }

      expect(alerts.count).to eq(1)
      expect(alerts.first.message).to include('refused')
      expect(alerts.first.recipient.company_id).to eq(company.id)
    end

    it "never alerts another company's admins" do
      other_admin = connector_user(connector_company, {}, role: 'company_admin')
      McpTools::Alerts::REFUSALS_PER_HOUR.times { call_tool(token, 'list_deals') }

      expect(Notification.where(recipient: other_admin)).to be_empty
    end
  end

  describe 'platform usage' do
    let(:platform_admin) do
      company.users.create!(email: "p-#{SecureRandom.hex(3)}@example.com", first_name: 'Pat', last_name: 'Form',
                            password: 'Pass1234!', role: 'platform_admin', status: 'active')
    end

    it 'lists every tenant with the add-on and its use' do
      call_tool(token, 'get_reference_data')
      call_tool(token, 'list_deals')
      idle = connector_company

      get '/api/admin/ai_connector_usage', headers: app_headers(platform_admin)

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      row = body['tenants'].find { |t| t['company_id'] == company.id }
      expect(row).to include('enabled' => true, 'connections' => 1, 'people' => 1, 'calls_30_days' => 2,
                             'refused_30_days' => 1)
      expect(body['tenants'].map { |t| t['company_id'] }).to include(idle.id)
      expect(body['apps']).to eq('Claude' => 2)
      expect(body['totals']['tenants_enabled']).to be >= 2
    end

    it 'is closed to company admins' do
      get '/api/admin/ai_connector_usage', headers: app_headers(admin)
      expect(response).to have_http_status(:forbidden)
    end
  end
end
