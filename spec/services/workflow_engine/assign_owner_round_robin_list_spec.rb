# frozen_string_literal: true

require 'rails_helper'

# Covers the new 'round_robin_list' strategy on the AssignOwner workflow
# executor. It shares the RoundRobinAssignmentList model with the inbound
# webhook api keys so one list + one cursor drive both tokens and workflows.
RSpec.describe WorkflowEngine::StepExecutors::AssignOwner, type: :service do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  def make_user(status: 'active')
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'sales_rep', status: status)
  end
  let(:u1) { make_user }
  let(:u2) { make_user }
  let(:u3) { make_user }
  let(:list) { RoundRobinAssignmentList.create!(company: company, name: 'Sales', user_ids: [u1.id, u2.id, u3.id]) }

  def run_executor_with(lead:, list_id:)
    rule = WorkflowRule.create!(
      company: company, name: 'r', entity_type: 'Lead', status: 'active',
      trigger: {}, conditions: [], steps: { 'nodes' => [] }
    )
    run = WorkflowRun.create!(
      company: company, workflow_rule: rule, entity_type: 'Lead', entity_id: lead.id,
      status: 'running', current_step_id: 'step_1', started_at: Time.current, rule_snapshot: rule.steps
    )
    step = { 'id' => 'step_1', 'type' => 'assign_owner',
             'config' => { 'strategy' => 'round_robin_list', 'round_robin_list_id' => list_id } }
    described_class.new(run: run, step: step).call
    lead.reload
  end

  it 'assigns the lead to the next user in the shared list and advances the cursor' do
    lead = Lead.create!(company_id: company.id, first_name: 'A', last_name: 'A')
    run_executor_with(lead: lead, list_id: list.id)
    expect(lead.owner_id).to eq(u1.id)

    lead2 = Lead.create!(company_id: company.id, first_name: 'B', last_name: 'B')
    run_executor_with(lead: lead2, list_id: list.id)
    expect(lead2.owner_id).to eq(u2.id)
  end

  it 'skips inactive users when picking' do
    u2.update!(status: 'inactive')
    lead = Lead.create!(company_id: company.id, first_name: 'A', last_name: 'A')
    run_executor_with(lead: lead, list_id: list.id)
    expect(lead.owner_id).to eq(u1.id)

    lead2 = Lead.create!(company_id: company.id, first_name: 'B', last_name: 'B')
    run_executor_with(lead: lead2, list_id: list.id)
    expect(lead2.owner_id).to eq(u3.id) # u2 skipped
  end

  it 'no-ops when the referenced list does not exist (returns skipped)' do
    lead = Lead.create!(company_id: company.id, first_name: 'A', last_name: 'A')
    run_executor_with(lead: lead, list_id: 999_999)
    expect(lead.owner_id).to be_nil
  end
end
