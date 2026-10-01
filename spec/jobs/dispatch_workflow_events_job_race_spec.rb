# frozen_string_literal: true

require 'rails_helper'

# Every WorkflowEngine.emit enqueues this job, so one save that emits two
# events runs two copies at once. Both used to read the same undispatched
# event and start its rules twice (seen on staging as two identical
# "Confirm interest" calls, and in production as duplicate runs of "Day 0 -
# New Lead First Touch").
RSpec.describe DispatchWorkflowEventsJob do
  let(:company) { create(:company) }

  it 'starts a rule once even when two dispatch jobs read the same event' do
    rule = WorkflowRule.create!(
      company_id: company.id, name: 'Confirm interest', entity_type: 'Lead', status: 'active',
      trigger: { 'event_type' => 'lead.status_changed', 'entity_type_filter' => 'Lead' },
      steps: { 'nodes' => [{ 'id' => 'n1', 'type' => 'wait', 'config' => { 'duration' => 1 } }] }
    )
    lead = company.leads.create!(first_name: 'Reese', last_name: 'M', email: 'r@example.com', status: 'new')
    WorkflowEvent.where(entity_id: lead.id).delete_all
    WorkflowEngine.emit('lead.status_changed', lead, { id: lead.id, from: 'new', to: 'contacted' })

    # Both jobs loaded the batch before either marked it dispatched.
    stale = WorkflowEvent.undispatched.to_a
    allow(WorkflowEvent).to receive(:undispatched).and_return(double(where: double(limit: stale)))
    2.times { described_class.new.perform }

    expect(WorkflowRun.where(workflow_rule_id: rule.id, entity_id: lead.id).count).to eq(1)
    expect(WorkflowEvent.find(stale.first.id).dispatched_at).to be_present
  end

  it 'still marks an event whose record is gone, with the reason' do
    WorkflowRule.create!(
      company_id: company.id, name: 'Any', entity_type: 'Lead', status: 'active',
      trigger: { 'event_type' => 'lead.status_changed', 'entity_type_filter' => 'Lead' },
      steps: { 'nodes' => [{ 'id' => 'n1', 'type' => 'wait', 'config' => { 'duration' => 1 } }] }
    )
    event = WorkflowEvent.create!(company_id: company.id, event_type: 'lead.status_changed', entity_type: 'Lead',
                                  entity_id: 0, payload: {})

    described_class.new.perform

    expect(event.reload.dispatched_at).to be_present
    expect(event.dispatch_error).to eq('reason' => 'entity_not_found')
  end
end
