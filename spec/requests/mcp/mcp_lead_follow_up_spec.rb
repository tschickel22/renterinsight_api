# frozen_string_literal: true

require 'rails_helper'
require_relative '../../support/mcp_connector_helpers'

# Finding leads that fell through the cracks and putting a next step on them.
# Factory Direct had about 2,200 open leads and about 210 with anything
# scheduled; this is the path the lead-follow-up skill drives.
RSpec.describe 'MCP lead follow-up', :mcp, type: :request do
  before { seed_rbac! }

  let(:company) { connector_company }
  let(:denver) { company.locations.create!(name: 'Denver', timezone: 'America/Denver') }
  let(:user) { connector_user(company, { 'leads' => %w[read update], 'crm' => %w[read create update] }) }
  let(:rep) { company.users.create!(email: "rep-#{SecureRandom.hex(3)}@example.com", first_name: 'Rita', last_name: 'Rep', password: 'Pass1234!', role: 'user', status: 'active') }
  let(:token) { connect!(user)['access_token'] }

  before do
    company.lead_statuses.create!(key: 'new', label: 'New', is_excluded: false, is_active: true)
    company.lead_statuses.create!(key: 'junk_lead', label: 'Junk Lead', is_excluded: true, is_active: true)
  end

  def lead!(attrs = {})
    company.leads.create!({ first_name: 'Maria', last_name: 'Lopez', email: "m-#{SecureRandom.hex(3)}@example.com",
                            status: 'new', location_id: denver.id, owner_id: rep.id }.merge(attrs))
  end

  def follow_up!(lead, due: 2.days.from_now)
    lead.lead_activities.create!(activity_type: 'task', subject: 'Call back', status: 'pending', priority: 'medium',
                                 due_date: due, user_id: rep.id, assigned_to_id: rep.id)
  end

  describe 'list_leads' do
    it 'leaves closed statuses out unless asked, and finds quiet leads with nothing scheduled' do
      quiet = lead!
      scheduled = lead!.tap { |l| follow_up!(l) }
      recent = lead!
      junk = lead!(status: 'junk_lead')
      # Set after the fact: creating a lead or a follow-up stamps last_activity_at.
      [quiet, scheduled].each { |l| l.update_columns(last_activity_at: 40.days.ago, created_at: 60.days.ago) }
      junk.update_columns(last_activity_at: 90.days.ago, created_at: 90.days.ago)
      recent.update_columns(last_activity_at: 1.day.ago)

      result, = call_tool(token, 'list_leads', sort: 'stale', quiet_days: 30, no_follow_up: true)
      ids = result['items'].map { |i| i['id'] }
      expect(ids).to eq(["lead:#{quiet.id}"])
      expect(ids).not_to include("lead:#{recent.id}", "lead:#{junk.id}")

      junk_result, = call_tool(token, 'list_leads', status: 'junk_lead')
      expect(junk_result['items'].map { |i| i['id'] }).to eq(["lead:#{junk.id}"])
    end
  end

  describe 'lead_follow_up_gaps' do
    it 'counts open leads, quiet ones, ones with nothing scheduled and overdue follow-ups, per owner' do
      lead!.update_columns(last_activity_at: 30.days.ago, created_at: 30.days.ago)
      lead!.tap { |l| follow_up!(l, due: 1.day.ago) }
      lead!.tap { |l| follow_up!(l) }
      lead!(status: 'junk_lead')
      lead!(owner_id: nil)

      result, error = call_tool(token, 'lead_follow_up_gaps', quiet_days: 14)
      expect(error).to be_falsey
      expect(result['totals']).to eq('open_leads' => 4, 'quiet' => 1, 'no_follow_up' => 2, 'overdue_follow_up' => 1)
      rita = result['by_owner'].find { |r| r['owner'] == 'Rita Rep' }
      expect(rita).to include('open_leads' => 3, 'no_follow_up' => 1)
      expect(result['by_owner'].map { |r| r['owner'] }).to include('Unassigned')
      expect(result['by_status'].map { |r| r['status'] }).to eq(['new'])
    end

    it "does not count another company's leads" do
      other = connector_company
      other.leads.create!(first_name: 'X', last_name: 'Y', email: 'x@example.com', status: 'new')
      result, = call_tool(token, 'lead_follow_up_gaps')
      expect(result['totals']['open_leads']).to eq(0)
    end
  end

  describe 'add_lead_follow_up' do
    it "creates a lead activity for the lead's owner, due in the dealer's time, and undo cancels it" do
      lead = lead!
      result, error, text = call_tool(token, 'add_lead_follow_up', id: "lead:#{lead.id}",
                                                                        subject: 'Call about the 3 bed', due_date: '2026-10-06')
      expect(error).to be_falsey, text
      activity = lead.lead_activities.last
      expect(activity).to have_attributes(activity_type: 'task', status: 'pending', assigned_to_id: rep.id, user_id: user.id)
      expect(activity.due_date).to eq(ActiveSupport::TimeZone['America/Denver'].parse('2026-10-06 17:00'))
      expect(result.dig('scheduled', 'assigned_to')).to eq('Rita Rep')

      change = McpChange.find_by!(record_type: 'LeadActivity', record_id: activity.id)
      expect(McpTools::Undo.describe(change)).to eq("Created lead follow-up #{activity.id}")
      expect(McpTools::Undo.undo!(change, by: user)).to be_undone
      expect(activity.reload.status).to eq('cancelled')
    end

    it 'schedules a call as an outbound call' do
      lead = lead!
      call_tool(token, 'add_lead_follow_up', id: "lead:#{lead.id}", subject: 'Ring her', due_date: '2026-10-06T10:00', kind: 'call')
      expect(lead.lead_activities.last).to have_attributes(activity_type: 'call', call_direction: 'outbound')
    end

    it 'needs CRM create, as the lead page does' do
      reader = connector_user(company, { 'leads' => %w[read update], 'crm' => %w[read] })
      lead = lead!
      _, error, text = call_tool(connect!(reader)['access_token'], 'add_lead_follow_up',
                                 id: "lead:#{lead.id}", subject: 'Call', due_date: '2026-10-06')
      expect(error).to be(true)
      expect(text).to include('does not allow create')
      expect(lead.lead_activities.count).to eq(0)
    end

    it 'is hidden from a read-only connection' do
      read_only = connect!(user, allow_write: false)['access_token']
      names = mcp_post(read_only, 'tools/list').dig('result', 'tools').map { |t| t['name'] }
      expect(names).to include('lead_follow_up_gaps')
      expect(names).not_to include('add_lead_follow_up')
    end
  end
end
