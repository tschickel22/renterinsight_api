# frozen_string_literal: true

require 'rails_helper'
require_relative '../../support/mcp_connector_helpers'

# Campaigns, workflows and nurture through the connector. The rule: the AI
# reads freely, adds one person at a time to an existing sequence, and builds
# workflows and campaigns only as drafts. Activating, starting and sending stay
# with a person in DealerTide, and the AI is told exactly that.
RSpec.describe 'MCP marketing tools', :mcp, type: :request do
  include ActiveJob::TestHelper

  before do
    seed_rbac!
    %w[management.workflows marketing.campaigns].each do |key|
      TenantModuleOverride.create!(company_id: company.id, module_key: key, is_enabled: true)
    end
  end

  let(:company) { connector_company }
  let(:denver) { company.locations.create!(name: 'Denver', timezone: 'America/Denver') }
  let(:grants) do
    { 'leads' => %w[read], 'crm' => %w[read create update], 'workflow_automation' => %w[read create update],
      'campaigns' => %w[read create] }
  end
  let(:user) { connector_user(company, grants) }
  let(:token) { connect!(user)['access_token'] }
  let(:lead) do
    company.leads.create!(first_name: 'Maria', last_name: 'Lopez', email: 'maria@example.com', phone: '3035550100',
                          status: 'new', location_id: denver.id)
  end

  def sequence!(name, active: true)
    company.nurture_sequences.create!(name: name, is_active: active).tap do |s|
      s.nurture_steps.create!(step_type: 'email', channel: 'email', subject: 'Hello', body: 'Hi', wait_days: 0, position: 0)
    end
  end

  let(:valid_steps) do
    { 'nodes' => [{ 'id' => 'step_1', 'type' => 'create_activity',
                    'config' => { 'subject' => 'Call {{entity.first_name}}', 'activity_type' => 'call',
                                  'assigned_to' => 'owner', 'due_in_hours' => 4 } }],
      'edges' => [] }
  end

  describe 'boundaries' do
    it 'tells the AI what it cannot do and where the user does it instead' do
      instructions = mcp_post(token, 'initialize', { protocolVersion: '2025-06-18', capabilities: {},
                                                     clientInfo: { name: 'claude-ai', version: '1' } })
                     .dig('result', 'instructions')

      expect(instructions).to include('has to be activated in', 'click Start', 'I cannot delete records',
                                      'I cannot send messages', 'one record at a time')
      expect(instructions).not_to match(/[–—]/)
    end

    it 'points to the exact page for the things it cannot do' do
      instructions = mcp_post(token, 'initialize', { protocolVersion: '2025-06-18', capabilities: {},
                                                     clientInfo: { name: 'claude-ai', version: '1' } })
                     .dig('result', 'instructions')

      expect(instructions).to include('/accounting/journal-entries', '/commissions/payments', '/accounting/bills',
                                      '/settings?tab=ai-apps', 'Settings, Integrations, AI Apps')
    end

    it 'exposes no tool that activates, starts, schedules or sends' do
      names = mcp_post(token, 'tools/list').dig('result', 'tools').map { |t| t['name'] }
      expect(names).to include('create_workflow_draft', 'create_campaign_draft', 'enroll_in_nurture')
      expect(names.grep(/activate|start|schedule|send|delete|test/)).to be_empty
    end

    it 'says the plan lacks campaigns rather than failing quietly' do
      TenantModuleOverride.where(company_id: company.id, module_key: 'marketing.campaigns').delete_all
      _r, is_error, text = call_tool(token, 'list_campaigns')

      expect(is_error).to be(true)
      expect(text).to include('not part of this account')
    end
  end

  describe 'reading' do
    it 'lists campaigns with their results and rates' do
      company.campaigns.create!(name: 'Fall open house', channel: 'email', status: 'completed', campaign_type: 'blast',
                                from_identity_type: 'Owner', created_by_user_id: user.id,
                                stats_cache: { 'total_sent' => 200, 'opened' => 90, 'clicked' => 20, 'replied' => 5 })
      body, = call_tool(token, 'list_campaigns')

      expect(body['items'].first).to include('name' => 'Fall open house', 'status' => 'completed')
      expect(body['items'].first['results']).to include('sent' => 200, 'open_rate_pct' => 45.0, 'reply_rate_pct' => 2.5)
    end

    it 'lists nurture sequences with steps and how many are enrolled' do
      seq = sequence!('New lead welcome')
      NurtureEnrollment.create!(enrollable: lead, nurture_sequence: seq, company: company, status: 'paused')
      body, = call_tool(token, 'list_nurture_sequences')

      row = body['items'].find { |s| s['id'] == "sequence:#{seq.id}" }
      expect(row['steps'].first).to include('type' => 'email')
      expect(row['enrolled']).to include('paused' => 1, 'running' => 0)
    end
  end

  describe 'enrolling in a nurture sequence' do
    it 'starts the sequence, pauses any other running one, and says the first step is sending' do
      other = sequence!('Old sequence')
      running = NurtureEnrollment.create!(enrollable: lead, nurture_sequence: other, company: company, status: 'running')
      seq = sequence!('New lead welcome')

      body = nil
      expect { body, = call_tool(token, 'enroll_in_nurture', id: "lead:#{lead.id}", sequence_id: "sequence:#{seq.id}") }
        .to have_enqueued_job(ProcessNurtureStepJob)

      expect(NurtureEnrollment.find_by(nurture_sequence: seq, enrollable: lead).status).to eq('running')
      expect(running.reload.status).to eq('paused')
      expect(body['paused_other_sequences']).to eq(['Old sequence'])
      expect(body['note']).to include('sending now')
    end

    it 'refuses a second copy, a turned off sequence, and another company\'s sequence' do
      seq = sequence!('Welcome')
      call_tool(token, 'enroll_in_nurture', id: "lead:#{lead.id}", sequence_id: "sequence:#{seq.id}")
      _r, err1, text1 = call_tool(token, 'enroll_in_nurture', id: "lead:#{lead.id}", sequence_id: "sequence:#{seq.id}")

      off = sequence!('Retired', active: false)
      _r, err2, text2 = call_tool(token, 'enroll_in_nurture', id: "lead:#{lead.id}", sequence_id: "sequence:#{off.id}")

      foreign = connector_company.nurture_sequences.create!(name: 'Theirs', is_active: true)
      _r, err3, = call_tool(token, 'enroll_in_nurture', id: "lead:#{lead.id}", sequence_id: "sequence:#{foreign.id}")

      expect([err1, err2, err3]).to all(be(true))
      expect(text1).to include('already in Welcome')
      expect(text2).to include('turned off')
      expect(NurtureEnrollment.where(nurture_sequence: foreign)).to be_empty
    end

    it 'undo pauses the enrollment, and leaves the sequence it paused alone' do
      other = sequence!('Old')
      NurtureEnrollment.create!(enrollable: lead, nurture_sequence: other, company: company, status: 'running')
      seq = sequence!('New')
      call_tool(token, 'enroll_in_nurture', id: "lead:#{lead.id}", sequence_id: "sequence:#{seq.id}")
      admin = connector_user(company, {}, role: 'company_admin')

      post "/api/v1/connected-apps/#{OauthGrant.last.id}/undo_recent", params: { hours: 1 }, headers: app_headers(admin)

      expect(NurtureEnrollment.find_by(nurture_sequence: seq).status).to eq('paused')
      expect(response.parsed_body['skipped_changes'].first['message']).to include('Resume it on the record')
    end
  end

  describe 'workflow drafts' do
    it 'saves a draft that cannot run, and tells the AI to have the user activate it' do
      body, = call_tool(token, 'create_workflow_draft', name: 'Call new leads', record_type: 'Lead',
                                                        trigger: { event_type: 'lead.created' }, steps: valid_steps)
      rule = WorkflowRule.find(body.dig('draft', 'id').split(':').last)

      expect(rule.status).to eq('draft')
      expect(rule.workflow_subscriptions).to be_empty
      expect(body['next_step']).to include('DRAFT', 'click Activate', "/workflow-automation/rules/#{rule.id}")
    end

    it 'returns the fixes and saves nothing when the workflow is not valid' do
      _r, is_error, text = call_tool(token, 'create_workflow_draft', name: 'Broken', record_type: 'Lead',
                                                                     trigger: { event_type: 'lead.created' },
                                                                     steps: { 'nodes' => [{ 'id' => 's1', 'type' => 'wait', 'config' => {} }] })
      expect(is_error).to be(true)
      expect(text).to include('nothing was saved')
      expect(WorkflowRule.count).to eq(0)
    end

    it 'refuses webhook steps and dashes in copy' do
      hook = { 'nodes' => [{ 'id' => 's1', 'type' => 'call_webhook', 'config' => { 'url' => 'https://x.example.com' } }] }
      _r, e1, t1 = call_tool(token, 'create_workflow_draft', name: 'Out', record_type: 'Lead',
                                                             trigger: { event_type: 'lead.created' }, steps: hook)
      dashed = { 'nodes' => [{ 'id' => 's1', 'type' => 'send_email',
                               'config' => { 'to' => '{{entity.email}}', 'subject' => 'Hi', 'body' => "Great news — call us" } }] }
      _r, e2, t2 = call_tool(token, 'create_workflow_draft', name: 'Dash', record_type: 'Lead',
                                                             trigger: { event_type: 'lead.created' }, steps: dashed)

      expect([e1, e2]).to all(be(true))
      expect(t1).to include('Webhook steps')
      expect(t2).to include('em dashes')
      expect(WorkflowRule.count).to eq(0)
    end

    it 'edits a draft but refuses a live workflow, offering a new draft instead' do
      body, = call_tool(token, 'create_workflow_draft', name: 'Draft one', record_type: 'Lead',
                                                        trigger: { event_type: 'lead.created' }, steps: valid_steps)
      call_tool(token, 'update_workflow_draft', id: body.dig('draft', 'id'), name: 'Renamed')
      expect(WorkflowRule.last.name).to eq('Renamed')

      live = company.workflow_rules.create!(name: 'Live', entity_type: 'Lead', status: 'active',
                                            trigger: { 'event_type' => 'lead.created' }, steps: valid_steps)
      _r, is_error, text = call_tool(token, 'update_workflow_draft', id: "workflow:#{live.id}", name: 'Hacked')
      expect(is_error).to be(true)
      expect(text).to include('is active', 'new draft')
      expect(live.reload.name).to eq('Live')
    end

    it 'undo removes the draft and its edits, but not one a person has edited since' do
      body, = call_tool(token, 'create_workflow_draft', name: 'Mine', record_type: 'Lead',
                                                        trigger: { event_type: 'lead.created' }, steps: valid_steps)
      call_tool(token, 'update_workflow_draft', id: body.dig('draft', 'id'), name: 'Mine v2')
      kept, = call_tool(token, 'create_workflow_draft', name: 'Kept', record_type: 'Lead',
                                                        trigger: { event_type: 'lead.created' }, steps: valid_steps)
      WorkflowRule.find(kept.dig('draft', 'id').split(':').last).update!(name: 'Kept, edited by a person')
      admin = connector_user(company, {}, role: 'company_admin')

      post "/api/v1/connected-apps/#{OauthGrant.last.id}/undo_recent", params: { hours: 1 }, headers: app_headers(admin)

      expect(WorkflowRule.pluck(:name)).to eq(['Kept, edited by a person'])
    end
  end

  describe 'campaign drafts' do
    let(:steps) do
      [{ 'subject' => 'Open house Saturday, {{first_name}}', 'text' => "Hi {{first_name}},\n\nCome see the new homes.",
         'button_label' => 'Save my spot', 'button_url' => 'https://example.com/rsvp' },
       { 'subject' => 'Still time to RSVP', 'text' => 'We would love to see you.', 'wait_days' => 3 }]
    end
    let(:audience) { { record_type: 'Lead', rules: { type: 'and', children: [{ field: 'status', operator: 'equals', value: 'new' }] } } }

    it 'saves a draft that sends nothing, reports the audience size, and says how to start it' do
      lead
      body = nil
      expect do
        body, = call_tool(token, 'create_campaign_draft', name: 'Open house', channel: 'email', audience: audience, steps: steps)
      end.not_to have_enqueued_job

      campaign = Campaign.find(body.dig('draft', 'id').split(':').last)
      expect(campaign).to have_attributes(status: 'draft', campaign_type: 'drip', from_identity_type: 'User',
                                          from_identity_id: user.id)
      expect(campaign.campaign_steps.map(&:wait_days)).to eq([0, 3])
      expect(campaign.campaign_steps.first.body_blocks.map { |b| b['type'] }).to eq(%w[branded_header text button sender_cta footer_unsubscribe])
      expect(body.dig('draft', 'audience_matches_now')).to eq(1)
      expect(body['next_step']).to include('DRAFT', 'click Start', "/campaigns/#{campaign.id}", 'cannot start')
    end

    it 'rejects audience rules that do not work, and dashes in copy, saving nothing' do
      bad = { record_type: 'Lead', rules: { type: 'and', children: [{ field: 'status', operator: 'sounds_like', value: 'x' }] } }
      _r, e1, t1 = call_tool(token, 'create_campaign_draft', name: 'Bad', channel: 'email', audience: bad, steps: steps)
      dashed = [{ 'subject' => 'Hi', 'text' => "Big sale – this week" }]
      _r, e2, t2 = call_tool(token, 'create_campaign_draft', name: 'Dash', channel: 'email', audience: audience, steps: dashed)

      expect([e1, e2]).to all(be(true))
      expect(t1).to include('audience rules do not work')
      expect(t2).to include('em dashes')
      expect(Campaign.count).to eq(0)
    end

    it 'needs text for an SMS campaign' do
      _r, is_error, text = call_tool(token, 'create_campaign_draft', name: 'Text', channel: 'sms', audience: audience,
                                                                     steps: [{ 'subject' => 'x' }])
      expect(is_error).to be(true)
      expect(text).to include('sms_text')
    end

    it 'undo archives the draft while it is still a draft' do
      body, = call_tool(token, 'create_campaign_draft', name: 'Undo me', channel: 'email', audience: audience, steps: steps)
      admin = connector_user(company, {}, role: 'company_admin')
      post "/api/v1/connected-apps/changes/#{McpChange.last.id}/undo", headers: app_headers(admin)

      expect(Campaign.find(body.dig('draft', 'id').split(':').last)).to have_attributes(status: 'archived', is_deleted: true)
    end
  end
end
