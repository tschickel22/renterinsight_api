# frozen_string_literal: true

require 'rails_helper'

# Call activities require a direction. The workflow step never set one, so
# every call task a workflow created failed validation and failed its run.
RSpec.describe WorkflowEngine::StepExecutors::CreateActivity, type: :service do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:rep) do
    User.create!(email: "r-#{SecureRandom.hex(4)}@example.com", first_name: 'R', last_name: 'P',
                 password: 'Pass1234!', company_id: company.id, role: 'sales_rep', status: 'active')
  end
  let(:lead) { Lead.create!(company_id: company.id, first_name: 'Tia', last_name: 'May', owner_id: rep.id, phone: '352-807-4919') }
  let(:rule) do
    WorkflowRule.create!(company: company, name: 'r', entity_type: 'Lead', status: 'active',
                         trigger: {}, conditions: [], steps: { 'nodes' => [] })
  end
  let(:run) do
    WorkflowRun.create!(company: company, workflow_rule: rule, entity_type: 'Lead', entity_id: lead.id,
                        status: 'running', current_step_id: 'call', started_at: Time.current,
                        rule_snapshot: rule.steps, variables: {})
  end

  def create_call(extra = {})
    step = { 'id' => 'call', 'type' => 'create_activity',
             'config' => { 'activity_type' => 'call', 'subject' => 'Call new lead', 'due_in_minutes' => 15,
                           'assigned_to' => 'owner' }.merge(extra) }
    described_class.new(run: run, step: step).call
  end

  it 'creates an outbound call due in the minutes given' do
    result = create_call

    expect(result[:status]).to eq('success')
    call = LeadActivity.find(result[:output][:id])
    expect(call).to have_attributes(activity_type: 'call', call_direction: 'outbound', assigned_to_id: rep.id)
    expect(call.due_date).to be_within(1.minute).of(15.minutes.from_now)
  end

  it 'keeps a direction the step names' do
    result = create_call('call_direction' => 'inbound')

    expect(LeadActivity.find(result[:output][:id]).call_direction).to eq('inbound')
  end

  it "fills the call's phone number from the lead, so the call screen is not blank" do
    result = create_call

    expect(LeadActivity.find(result[:output][:id]).phone_number).to eq(lead.reload.phone)
  end

  it 'leaves the number empty when the lead has none, and keeps one the step names' do
    lead.update_columns(phone: nil)
    expect(LeadActivity.find(create_call[:output][:id]).phone_number).to be_blank
    expect(LeadActivity.find(create_call('phone_number' => '720-555-0100')[:output][:id]).phone_number).to eq('720-555-0100')
  end
end
