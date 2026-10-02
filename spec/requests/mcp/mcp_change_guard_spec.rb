# frozen_string_literal: true

require 'rails_helper'
require_relative '../../support/mcp_connector_helpers'

# Guarding against an AI app doing damage one allowed change at a time:
# per-person change limits, an admin alert when one is hit, and undo for
# everything it changed, one change or a whole runaway session at once.
RSpec.describe 'MCP change limits and undo', :mcp, type: :request do
  before { seed_rbac! }

  let(:company) { connector_company }
  let(:denver) { company.locations.create!(name: 'Denver', timezone: 'America/Denver') }
  let(:writes) do
    { 'leads' => %w[read create update], 'crm' => %w[read update], 'deals' => %w[read update],
      'service' => %w[read create], 'tasks' => %w[read create] }
  end
  let(:user) { connector_user(company, writes) }
  let!(:admin) { connector_user(company, {}, role: 'company_admin') }
  let(:tokens) { connect!(user) }
  let(:token) { tokens['access_token'] }
  let(:buyer) { company.contacts.create!(first_name: 'Ana', last_name: 'Diaz', location_id: denver.id) }

  def lead!(attrs = {})
    company.leads.create!({ first_name: 'Maria', last_name: 'Lopez', email: "m-#{SecureRandom.hex(3)}@example.com",
                            status: 'new', location_id: denver.id }.merge(attrs))
  end

  def undo(change, as: admin)
    post "/api/v1/connected-apps/changes/#{change.id}/undo", headers: app_headers(as)
    response.parsed_body
  end

  describe 'change limits' do
    it 'stops after the hourly limit, says why, and tells the admins once' do
      Setting.set('Company', company.id, 'mcp_settings', { 'hourly_change_limit' => 2 })
      lead = lead!

      2.times { |i| call_tool(token, 'add_note', id: "lead:#{lead.id}", text: "note #{i}") }
      _r, is_error, text = call_tool(token, 'add_note', id: "lead:#{lead.id}", text: 'one too many')
      call_tool(token, 'add_note', id: "lead:#{lead.id}", text: 'and another')

      expect(is_error).to be(true)
      expect(text).to include('2 changes an hour')
      expect(Note.where(entity_type: 'lead', entity_id: lead.id.to_s).count).to eq(2)
      alerts = Notification.where(company_id: company.id, notification_type: 'ai_connector_alert')
      expect(alerts.count).to eq(1)
      expect(alerts.first.message).to include('limit on changes')
    end

    it 'counts a status change and its note as one change' do
      Setting.set('Company', company.id, 'mcp_settings', { 'hourly_change_limit' => 1 })
      lead = lead!
      call_tool(token, 'update_lead_status', id: "lead:#{lead.id}", status: 'contacted', note: 'spoke to her')

      expect(McpChange.count).to eq(2)
      _r, is_error, = call_tool(token, 'add_note', id: "lead:#{lead.id}", text: 'next')
      expect(is_error).to be(true)
    end

    it 'never limits reading' do
      Setting.set('Company', company.id, 'mcp_settings', { 'hourly_change_limit' => 0 })
      _r, is_error, = call_tool(token, 'list_leads')
      expect(is_error).to be_falsey
    end

    it 'lets an admin set the change limits' do
      put '/api/v1/connected-apps/settings', params: { hourly_change_limit: 10, daily_change_limit: 50 },
                                             headers: app_headers(admin)
      expect(response.parsed_body).to include('hourly_change_limit' => 10, 'daily_change_limit' => 50,
                                              'daily_record_limit' => 2000)

      put '/api/v1/connected-apps/settings', params: { hourly_change_limit: -1 }, headers: app_headers(admin)
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe 'undo, one change at a time' do
    it 'restores a lead status, and shows the change in the activity' do
      lead = lead!
      call_tool(token, 'update_lead_status', id: "lead:#{lead.id}", status: 'contacted')

      get '/api/v1/connected-apps/activity', headers: app_headers(admin)
      change_row = response.parsed_body['calls'].first['changes'].first
      expect(change_row['description']).to include('"new" to "contacted"')

      expect(undo(McpChange.last)).to include('undone' => true)
      expect(lead.reload.status).to eq('new')
      expect(McpChange.last.undone_at).to be_present
    end

    it 'leaves a value alone that a person changed again since' do
      lead = lead!
      call_tool(token, 'update_lead_status', id: "lead:#{lead.id}", status: 'contacted')
      lead.update!(status: 'qualified')

      body = undo(McpChange.last)
      expect(body['undone']).to be(false)
      expect(body['message']).to include('Changed again since')
      expect(lead.reload.status).to eq('qualified')
    end

    it 'puts the owner back without notifying anyone' do
      original = connector_user(company, {})
      lead = lead!(owner_id: original.id)
      rep = connector_user(company, {})
      call_tool(token, 'assign_lead', id: "lead:#{lead.id}", user_id: rep.id)

      expect { undo(McpChange.last) }.not_to(change { Notification.where(recipient: original).count })
      expect(lead.reload.owner_id).to eq(original.id)
    end

    it 'deletes a note, cancels a task and a ticket rather than deleting them' do
      lead = lead!
      call_tool(token, 'add_note', id: "lead:#{lead.id}", text: 'AI note')
      call_tool(token, 'create_task', title: 'Call back', related_id: "lead:#{lead.id}")
      call_tool(token, 'create_service_ticket', title: 'Leak', description: 'Roof', customer_id: "contact:#{buyer.id}")
      note, task, ticket = McpChange.order(:id).map(&:record)

      McpChange.order(:id).each { |c| expect(undo(c)['undone']).to be(true) }

      expect(Note.exists?(note.id)).to be(false)
      expect(task.reload.status).to eq('cancelled')
      expect(ticket.reload.status).to eq('cancelled')
    end

    it 'deletes a lead the AI created only while nobody has worked it' do
      call_tool(token, 'create_lead', first_name: 'Sam', email: 'sam@example.com')
      untouched = McpChange.last
      call_tool(token, 'create_lead', first_name: 'Kim', email: 'kim@example.com')
      worked = McpChange.last
      worked.record.update!(status: 'contacted')

      expect(undo(untouched)['undone']).to be(true)
      expect(Lead.exists?(untouched.record_id)).to be(false)
      expect(undo(worked)['message']).to include('worked this lead')
      expect(Lead.exists?(worked.record_id)).to be(true)
    end

    it 'restores a deal stage with a history row, but will not reverse a win' do
      deal = company.deals.create!(name: 'Reed', stage: 'proposal', contact_id: buyer.id, location_id: denver.id)
      call_tool(token, 'update_deal_stage', id: "deal:#{deal.id}", stage: 'negotiation')
      expect(undo(McpChange.last)['undone']).to be(true)
      expect(deal.reload.stage).to eq('proposal')
      expect(deal.deal_stage_histories.last.notes).to eq(McpTools::Undo::UNDO_NOTE)

      call_tool(token, 'update_deal_stage', id: "deal:#{deal.id}", stage: 'closed_won')
      body = undo(McpChange.last)
      expect(body['undone']).to be(false)
      expect(body['message']).to include('accounting and inventory')
      expect(deal.reload.stage).to eq('closed_won')
    end

    it "lets a person undo their own AI app's change, not someone else's" do
      lead = lead!
      call_tool(token, 'update_lead_status', id: "lead:#{lead.id}", status: 'contacted')
      other = connector_user(company, { 'leads' => %w[read update] })

      undo(McpChange.last, as: other)
      expect(response).to have_http_status(:not_found)
      expect(undo(McpChange.last, as: user)['undone']).to be(true)
    end

    it "cannot reach another company's changes" do
      lead = lead!
      call_tool(token, 'update_lead_status', id: "lead:#{lead.id}", status: 'contacted')
      outsider = connector_user(connector_company, {}, role: 'company_admin')

      undo(McpChange.last, as: outsider)
      expect(response).to have_http_status(:not_found)
      expect(lead.reload.status).to eq('contacted')
    end
  end

  describe 'undo a whole session' do
    it "reverses everything a connection changed in the window, newest first, and reports what it skipped" do
      a = lead!
      b = lead!
      call_tool(token, 'update_lead_status', id: "lead:#{a.id}", status: 'lost')
      call_tool(token, 'update_lead_status', id: "lead:#{b.id}", status: 'lost')
      call_tool(token, 'update_lead_status', id: "lead:#{a.id}", status: 'unqualified')
      b.update!(status: 'qualified')

      post "/api/v1/connected-apps/#{OauthGrant.last.id}/undo_recent", params: { hours: 24 }, headers: app_headers(admin)
      body = response.parsed_body

      expect(a.reload.status).to eq('new')
      expect(b.reload.status).to eq('qualified')
      expect(body).to include('undone' => 2, 'skipped' => 1)
      expect(body['skipped_changes'].first['message']).to include('Changed again since')
    end
  end

  describe 'change log wording' do
    it 'names people and skips fields that did not change' do
      lead = lead!(owner_id: nil)
      rep = connector_user(company, {})
      call_tool(token, 'assign_lead', id: "lead:#{lead.id}", user_id: rep.id)

      text = McpTools::Undo.describe(McpChange.last)
      expect(text).to include("owner blank to #{rep.full_name}")
      expect(text).not_to include('nil')
    end
  end

  describe 'undo hint' do
    it 'tells the AI on every write where the person can undo it, and not on reads' do
      lead = lead!
      _r, is_error, text = call_tool(token, 'add_note', id: "lead:#{lead.id}", text: 'AI note')
      expect(is_error).to be(false)
      expect(JSON.parse(text)['undo']).to include('Settings, Integrations, AI Apps', '/settings?tab=ai-apps')

      _r, _e, read = call_tool(token, 'list_leads')
      expect(JSON.parse(read)).not_to have_key('undo')
    end
  end
end
