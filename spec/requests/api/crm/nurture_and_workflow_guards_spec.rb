# frozen_string_literal: true

require 'rails_helper'
require_relative '../../../support/mcp_connector_helpers'

# B37 to B39: nurture enrollment guards and permission checks, and workflow
# edits that would break a live rule.
RSpec.describe 'Nurture and workflow guards', :mcp, type: :request do
  include ActiveJob::TestHelper

  before { seed_rbac! }

  let(:company) { connector_company }
  let(:editor) { connector_user(company, { 'crm' => %w[read create update delete] }, connector: nil) }
  let(:reader) { connector_user(company, { 'crm' => %w[read] }, connector: nil) }
  let(:lead) { company.leads.create!(first_name: 'Maria', last_name: 'L', email: 'm@example.com', status: 'new') }
  let(:sequence) { company.nurture_sequences.create!(name: 'Welcome', is_active: true) }

  def json_headers(user)
    app_headers(user).merge('CONTENT_TYPE' => 'application/json')
  end

  describe 'enrolling (B37)' do
    def enroll(as: editor, **enrollment)
      post '/api/crm/nurture/enrollments', params: { enrollment: enrollment }.to_json, headers: json_headers(as)
    end

    it 'enrolls the record named by entity_type and entity_id, ready to send' do
      expect { enroll(entity_type: 'Lead', entity_id: lead.id, nurture_sequence_id: sequence.id, status: 'running') }
        .to have_enqueued_job(ProcessNurtureStepJob)

      expect(response).to have_http_status(:created)
      expect(NurtureEnrollment.last).to have_attributes(enrollable_type: 'Lead', enrollable_id: lead.id, status: 'running')
    end

    it 'gives a lead_id-only caller an enrollment the job can send for' do
      enroll(lead_id: lead.id, nurture_sequence_id: sequence.id, status: 'running')
      expect(NurtureEnrollment.last).to have_attributes(enrollable_type: 'Lead', enrollable_id: lead.id)
    end

    it "refuses another company's sequence, a turned off one, and a second copy" do
      foreign = connector_company.nurture_sequences.create!(name: 'Theirs', is_active: true)
      enroll(entity_type: 'Lead', entity_id: lead.id, nurture_sequence_id: foreign.id, status: 'running')
      expect(response).to have_http_status(:unprocessable_entity)

      off = company.nurture_sequences.create!(name: 'Off', is_active: false)
      enroll(entity_type: 'Lead', entity_id: lead.id, nurture_sequence_id: off.id, status: 'running')
      expect(response.parsed_body['error']).to include('turned off')

      enroll(entity_type: 'Lead', entity_id: lead.id, nurture_sequence_id: sequence.id, status: 'running')
      enroll(entity_type: 'Lead', entity_id: lead.id, nurture_sequence_id: sequence.id, status: 'running')
      expect(response.parsed_body['error']).to include('Already enrolled')
      expect(NurtureEnrollment.where(nurture_sequence: sequence).count).to eq(1)
    end

    it 'does not pause the running sequence when the new enrollment is refused' do
      other = company.nurture_sequences.create!(name: 'Other', is_active: true)
      running = NurtureEnrollment.create!(enrollable: lead, nurture_sequence: other, company: company, status: 'running')
      off = company.nurture_sequences.create!(name: 'Off', is_active: false)

      enroll(entity_type: 'Lead', entity_id: lead.id, nurture_sequence_id: off.id, status: 'running')
      expect(running.reload.status).to eq('running')
    end

    it 'skips turned off sequences and duplicates in bulk' do
      off = company.nurture_sequences.create!(name: 'Off', is_active: false)
      NurtureEnrollment.create!(enrollable: lead, nurture_sequence: sequence, company: company, status: 'running')
      upsert = [{ entity_type: 'Lead', entity_id: lead.id, nurture_sequence_id: off.id, status: 'running' },
                { entity_type: 'Lead', entity_id: lead.id, nurture_sequence_id: sequence.id, status: 'running' }]

      post '/api/crm/nurture/enrollments/bulk', params: { upsert: upsert }.to_json, headers: json_headers(editor)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to be_empty
      expect(NurtureEnrollment.count).to eq(1)
    end
  end

  describe 'permission checks on the actions that had none (B38)' do
    it 'needs crm create to bulk enroll and crm delete to bulk delete' do
      body = { upsert: [{ entity_type: 'Lead', entity_id: lead.id, nurture_sequence_id: sequence.id }] }
      post '/api/crm/nurture/enrollments/bulk', params: body.to_json, headers: json_headers(reader)
      expect(response).to have_http_status(:forbidden)

      creator = connector_user(company, { 'crm' => %w[read create] }, connector: nil)
      existing = NurtureEnrollment.create!(enrollable: lead, nurture_sequence: sequence, company: company, status: 'paused')
      post '/api/crm/nurture/enrollments/bulk', params: { delete: [existing.id] }.to_json, headers: json_headers(creator)
      expect(response).to have_http_status(:forbidden)
      expect(NurtureEnrollment.exists?(existing.id)).to be(true)
    end

    it 'needs crm update to trigger a step or send a test message' do
      enrollment = NurtureEnrollment.create!(enrollable: lead, nurture_sequence: sequence, company: company, status: 'running')
      post "/api/crm/nurture/enrollments/#{enrollment.id}/trigger_step", headers: json_headers(reader)
      expect(response).to have_http_status(:forbidden)

      step = sequence.nurture_steps.create!(step_type: 'email', channel: 'email', subject: 'Hi', body: 'Hello', position: 0)
      post "/api/crm/nurture/sequences/#{sequence.id}/steps/#{step.id}/send_test", headers: json_headers(reader)
      expect(response).to have_http_status(:forbidden)
    end

    it 'needs crm delete to bulk delete sequences' do
      updater = connector_user(company, { 'crm' => %w[read update] }, connector: nil)
      post '/api/crm/nurture/sequences/bulk', params: { delete: [sequence.id] }.to_json, headers: json_headers(updater)

      expect(response).to have_http_status(:forbidden)
      expect(NurtureSequence.exists?(sequence.id)).to be(true)
    end
  end

  describe 'live workflow edits (B39)' do
    let(:admin) { connector_user(company, {}, role: 'company_admin') }
    let(:valid_steps) do
      { 'nodes' => [{ 'id' => 'step_1', 'type' => 'create_activity',
                      'config' => { 'subject' => 'Call', 'activity_type' => 'call', 'assigned_to' => 'owner' } }],
        'edges' => [] }
    end
    let(:broken_steps) { { 'nodes' => [{ 'id' => 'step_1', 'type' => 'wait', 'config' => {} }], 'edges' => [] } }

    before { TenantModuleOverride.create!(company_id: company.id, module_key: 'management.workflows', is_enabled: true) }

    def rule(status)
      company.workflow_rules.create!(name: 'Rule', entity_type: 'Lead', status: status,
                                     trigger: { 'event_type' => 'lead.created' }, steps: valid_steps)
    end

    def edit(rule, steps)
      patch "/api/v1/workflow_rules/#{rule.id}", params: { workflow_rule: { steps: steps } }.to_json,
                                                 headers: json_headers(admin)
    end

    it 'refuses an edit that would break a live workflow, and keeps it running as it was' do
      live = rule('active')
      edit(live, broken_steps)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['error']).to include('This workflow is live')
      expect(live.reload.steps).to eq(valid_steps)
    end

    it 'saves a valid edit to a live workflow, and any edit to a draft' do
      edit(rule('active'), valid_steps.merge('edges' => []))
      expect(response).to have_http_status(:ok)

      draft = rule('draft')
      edit(draft, broken_steps)
      expect(response).to have_http_status(:ok)
      expect(draft.reload.steps).to eq(broken_steps)
    end

    it 'will not resume a paused workflow that is broken' do
      paused = rule('paused')
      paused.update_columns(steps: broken_steps)

      post "/api/v1/workflow_rules/#{paused.id}/resume", headers: json_headers(admin)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(paused.reload.status).to eq('paused')
    end
  end
end
