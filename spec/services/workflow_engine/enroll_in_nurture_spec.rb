# frozen_string_literal: true

require 'rails_helper'

# The workflow step used to create a "running" enrollment and queue nothing,
# so a nurture started from a workflow never sent a single message.
RSpec.describe WorkflowEngine::StepExecutors::EnrollInNurture, type: :service do
  include ActiveJob::TestHelper

  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:sequence) { NurtureSequence.create!(company_id: company.id, name: 'New lead welcome') }
  let(:lead) { Lead.create!(company_id: company.id, first_name: 'A', last_name: 'A') }

  before { ActiveJob::Base.queue_adapter = :test }

  def run_step(entity, sequence_id)
    rule = WorkflowRule.create!(
      company: company, name: 'r', entity_type: 'Lead', status: 'active',
      trigger: {}, conditions: [], steps: { 'nodes' => [] }
    )
    run = WorkflowRun.create!(
      company: company, workflow_rule: rule, entity_type: 'Lead', entity_id: entity.id,
      status: 'running', current_step_id: 'step_1', started_at: Time.current, rule_snapshot: rule.steps
    )
    step = { 'id' => 'step_1', 'type' => 'enroll_in_nurture',
             'config' => { 'nurture_sequence_id' => sequence_id } }
    described_class.new(run: run, step: step).call
  end

  it 'enrolls the entity and queues the first step' do
    result = nil
    expect { result = run_step(lead, sequence.id) }.to have_enqueued_job(ProcessNurtureStepJob)

    expect(result[:status]).to eq('success')
    enrollment = NurtureEnrollment.find(result[:output][:enrollment_id])
    expect(enrollment).to have_attributes(status: 'running', enrollable: lead, nurture_sequence_id: sequence.id)
  end

  it 'does not restart a sequence the entity is already running' do
    run_step(lead, sequence.id)

    result = nil
    expect { result = run_step(lead, sequence.id) }.not_to have_enqueued_job(ProcessNurtureStepJob)
    expect(result[:output][:reason]).to eq('already_enrolled')
    expect(NurtureEnrollment.for_entity('Lead', lead.id).count).to eq(1)
  end

  it 'pauses a different running sequence, as manual enrollment does' do
    other = NurtureSequence.create!(company_id: company.id, name: 'Other')
    first = NurtureEnrollment.create!(enrollable: lead, nurture_sequence: other, company: company, status: 'running')

    run_step(lead, sequence.id)

    expect(first.reload.status).to eq('paused')
  end

  it 'skips a sequence that belongs to another company' do
    other_company = Company.create!(name: "X-#{SecureRandom.hex(4)}", industry: 'manufactured_housing')
    foreign = NurtureSequence.create!(company_id: other_company.id, name: 'Theirs')

    result = run_step(lead, foreign.id)

    expect(result[:status]).to eq('skipped')
    expect(NurtureEnrollment.for_entity('Lead', lead.id).count).to eq(0)
  end
end
