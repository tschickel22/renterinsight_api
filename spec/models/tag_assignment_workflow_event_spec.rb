# frozen_string_literal: true

require 'rails_helper'

# Adding a tag should fire a `<entity>.tagged` workflow event so automations can
# trigger on it (e.g. "when tagged 'hot-lead' -> start nurture"). Covers the
# emission itself, the tag payload, the entity-type guard, and the loop guard.
RSpec.describe 'TagAssignment workflow tagged event', type: :model do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:lead)    { Lead.create!(company_id: company.id, first_name: 'A', last_name: 'B', email: 'a@x.com', status: 'new') }
  let(:tag)     { Tag.create!(name: 'hot-lead', color: '#f00', is_active: true, created_by: 'system') }

  def tag_the_lead
    TagAssignment.create!(company_id: company.id, tag: tag, entity_type: 'Lead', entity_id: lead.id,
                          assigned_by: 'system', assigned_at: Time.current)
  end

  it 'emits a lead.tagged workflow event carrying the tag id and name' do
    expect { tag_the_lead }.to change {
      WorkflowEvent.where(company_id: company.id, event_type: 'lead.tagged', entity_id: lead.id).count
    }.by(1)

    event = WorkflowEvent.where(event_type: 'lead.tagged', entity_id: lead.id).order(:id).last
    expect(event.entity_type).to eq('Lead')
    expect(event.payload['tag_id']).to eq(tag.id)
    expect(event.payload['tag_name']).to eq('hot-lead')
  end

  it 'does not emit for entity types without a tagged trigger (e.g. Vehicle)' do
    expect {
      TagAssignment.create!(company_id: company.id, tag: tag, entity_type: 'Vehicle', entity_id: 999_999,
                            assigned_by: 'system', assigned_at: Time.current)
    }.not_to change { WorkflowEvent.where(event_type: 'vehicle.tagged').count }
  end

  it 'is suppressed while a workflow step is executing (loop guard)' do
    Current.suppress_workflow_events = true
    expect { tag_the_lead }.not_to change { WorkflowEvent.where(event_type: 'lead.tagged').count }
  ensure
    Current.suppress_workflow_events = nil
  end

  it 'triggers an active rule whose tags_include condition matches the new tag' do
    rule = WorkflowRule.create!(
      company_id: company.id,
      name: 'Nurture hot leads',
      entity_type: 'Lead',
      status: 'active',
      trigger: { 'event_type' => 'lead.tagged' },
      conditions: { 'type' => 'and', 'children' => [
        { 'field' => 'tags', 'operator' => 'tags_include', 'value' => 'hot-lead' }
      ] },
      steps: { 'nodes' => [{ 'id' => 'n1', 'type' => 'wait', 'config' => { 'duration' => 1 } }] }
    )
    # after_save sync_subscriptions should have registered the subscription
    expect(WorkflowSubscription.where(company_id: company.id, event_type: 'lead.tagged').count).to eq(1)

    tag_the_lead
    event = WorkflowEvent.where(event_type: 'lead.tagged', entity_id: lead.id).order(:id).last

    expect { DispatchWorkflowEventsJob.new.perform }.to change {
      WorkflowRun.where(workflow_rule_id: rule.id, entity_id: lead.id).count
    }.by(1)
    expect(event.reload.dispatched_at).to be_present
  end
end
