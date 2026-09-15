# frozen_string_literal: true

require 'rails_helper'

# A workflow message used to carry the booking link of whoever wrote the rule,
# baked in at generation time. It now resolves to the link of the rep who owns
# the record, including a rep the workflow itself just assigned.
RSpec.describe 'Rep booking link in workflow messages', type: :service do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }

  def make_user(booking_url:)
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'Rep', last_name: SecureRandom.hex(2),
                 password: 'Pass1234!', company_id: company.id, role: 'sales_rep', status: 'active',
                 booking_url: booking_url)
  end

  let(:first_rep)  { make_user(booking_url: 'https://calendly.com/first-rep') }
  let(:second_rep) { make_user(booking_url: 'https://calendly.com/second-rep') }

  let(:rule) do
    WorkflowRule.create!(company: company, name: 'r', entity_type: 'Lead', status: 'active',
                         trigger: {}, conditions: [], steps: { 'nodes' => [] })
  end

  it "puts the owner's booking link on the entity" do
    lead = Lead.create!(company_id: company.id, first_name: 'A', last_name: 'B', owner_id: first_rep.id)

    expect(WorkflowEngine.entity_hash(lead)['owner_booking_url']).to eq('https://calendly.com/first-rep')
  end

  it 'offers {{rep_booking_link}} from the start of a run' do
    lead = Lead.create!(company_id: company.id, first_name: 'A', last_name: 'B', owner_id: first_rep.id)

    run = WorkflowEngine.start_run(rule: rule, entity: lead)

    expect(WorkflowEngine::VariableResolver.resolve('Book: {{rep_booking_link}}', run.variables))
      .to eq('Book: https://calendly.com/first-rep')
  end

  it 'uses the newly assigned rep for messages after an assign_owner step' do
    lead = Lead.create!(company_id: company.id, first_name: 'A', last_name: 'B', owner_id: first_rep.id)
    run = WorkflowRun.create!(
      company: company, workflow_rule: rule, entity_type: 'Lead', entity_id: lead.id,
      status: 'running', current_step_id: 'step_1', started_at: Time.current, rule_snapshot: rule.steps,
      variables: { 'entity' => WorkflowEngine.entity_hash(lead) }
    )
    step = { 'id' => 'step_1', 'type' => 'assign_owner',
             'config' => { 'strategy' => 'specific_user', 'user_id' => second_rep.id } }

    WorkflowEngine::StepExecutors::AssignOwner.new(run: run, step: step).call

    variables = run.reload.variables
    expect(WorkflowEngine::VariableResolver.resolve('{{entity.owner_booking_url}}', variables))
      .to eq('https://calendly.com/second-rep')
    expect(variables['rep_booking_link']).to eq('https://calendly.com/second-rep')
  end
end
