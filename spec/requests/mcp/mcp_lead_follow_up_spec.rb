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

    it 'names owners who cannot take work and marks them not assignable, without naming another company\'s user' do
      gone = company.users.create!(email: "gone-#{SecureRandom.hex(3)}@example.com", first_name: 'Gus', last_name: 'Gone',
                                   password: 'Pass1234!', role: 'user', status: 'inactive')
      outsider = connector_company.users.create!(email: "out-#{SecureRandom.hex(3)}@example.com", first_name: 'Olga',
                                                 last_name: 'Outsider', password: 'Pass1234!', role: 'user', status: 'active')
      lead!
      lead!(owner_id: gone.id)
      lead!.update_columns(owner_id: outsider.id)

      result, = call_tool(token, 'lead_follow_up_gaps')
      rows = result['by_owner'].index_by { |r| r['owner_id'] }
      expect(rows[rep.id]).to include('owner' => 'Rita Rep')
      expect(rows[rep.id]).not_to have_key('assignable')
      expect(rows[gone.id]).to include('owner' => 'Gus Gone (inactive)', 'owner_status' => 'inactive', 'assignable' => false)
      expect(rows[outsider.id]).to include('owner' => "Not a user at #{company.name}", 'owner_status' => 'not_a_user_here',
                                           'assignable' => false)
      expect(result.to_json).not_to include('Olga', 'User ')
    end

    it "does not count another company's leads" do
      other = connector_company
      other.leads.create!(first_name: 'X', last_name: 'Y', email: 'x@example.com', status: 'new')
      result, = call_tool(token, 'lead_follow_up_gaps')
      expect(result['totals']['open_leads']).to eq(0)
    end
  end

  describe 'pipeline_summary' do
    let(:user) { connector_user(company, { 'leads' => %w[read], 'crm' => %w[read] }) }

    it 'counts open leads the way lead_follow_up_gaps does, leaving closed statuses out' do
      2.times { lead! }
      lead!(status: 'junk_lead')

      summary, = call_tool(token, 'pipeline_summary')
      gaps, = call_tool(token, 'lead_follow_up_gaps')
      expect(summary['open_leads_by_status']).to eq([{ 'status' => 'new', 'label' => 'New', 'count' => 2 }])
      expect(summary['open_leads_total']).to eq(2)
      expect(summary['open_leads_total']).to eq(gaps.dig('totals', 'open_leads'))
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

    it "reads a local time in the lead's location zone and says which zone it used" do
      lead = lead!
      result, error, text = call_tool(token, 'add_lead_follow_up', id: "lead:#{lead.id}", subject: 'Call',
                                                                        due_date: '2026-10-06T10:00')
      expect(error).to be_falsey, text
      expect(lead.lead_activities.last.due_date).to eq(Time.utc(2026, 10, 6, 16, 0))
      expect(result['scheduled']).to include('due' => '2026-10-06T10:00:00-06:00', 'due_utc' => '2026-10-06T16:00:00Z',
                                             'time_zone' => 'America/Denver', 'time_zone_source' => 'location Denver')
      expect(result['scheduled']).not_to have_key('time_zone_warning')
    end

    it 'warns when the location zone does not fit its state, as on Summit Park staging' do
      # locations.timezone defaults to Eastern, so a Colorado lot nobody set up reads as Eastern.
      showroom = company.locations.create!(name: 'Denver Showroom', city: 'Denver', state: 'CO')
      expect(showroom.timezone).to eq('America/New_York')
      lead = lead!(location_id: showroom.id)

      result, = call_tool(token, 'add_lead_follow_up', id: "lead:#{lead.id}", subject: 'Call', due_date: '2026-10-06T10:00')
      # The app reads this location in Eastern, so the connector does too, and says so.
      expect(lead.lead_activities.last.due_date).to eq(Time.utc(2026, 10, 6, 14, 0))
      expect(result['scheduled']).to include('time_zone' => 'America/New_York', 'time_zone_source' => 'location Denver Showroom')
      expect(result['scheduled']['time_zone_warning']).to include('Denver Showroom is in CO', 'Settings, Locations')
    end

    it "falls back to the company's time zone setting when the lead has no location" do
      Setting.set('Company', company.id, 'operational_settings', { 'timezone' => 'America/Chicago' })
      lead = lead!(location_id: nil)

      result, = call_tool(token, 'add_lead_follow_up', id: "lead:#{lead.id}", subject: 'Call', due_date: '2026-10-06T10:00')
      expect(lead.lead_activities.last.due_date).to eq(Time.utc(2026, 10, 6, 15, 0))
      expect(result['scheduled']).to include('time_zone' => 'America/Chicago', 'time_zone_source' => 'company time zone setting')
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
