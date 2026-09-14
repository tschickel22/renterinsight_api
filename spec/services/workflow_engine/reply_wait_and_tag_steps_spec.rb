# frozen_string_literal: true

require 'rails_helper'

# Three steps a new-lead play leans on, each of which silently did nothing:
# wait_for_reply never timed out, a text reply never reached its run, and
# add_tag never tagged.
RSpec.describe 'Reply wait, SMS reply matching and add_tag steps', type: :service do
  include ActiveSupport::Testing::TimeHelpers

  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:owner) do
    User.create!(email: "o-#{SecureRandom.hex(4)}@example.com", first_name: 'Olive', last_name: 'Owner',
                 password: 'Pass1234!', company_id: company.id, role: 'sales_rep', status: 'active')
  end
  let(:lead) do
    Lead.create!(company_id: company.id, first_name: 'Tia', last_name: 'May', email: 'tia@example.com',
                 phone: '3035551212', owner_id: owner.id)
  end
  let(:rule) do
    WorkflowRule.create!(company: company, name: 'r', entity_type: 'Lead', status: 'active',
                         trigger: {}, conditions: [], steps: { 'nodes' => [] })
  end
  let(:run) do
    WorkflowRun.create!(company: company, workflow_rule: rule, entity_type: 'Lead', entity_id: lead.id,
                        status: 'running', current_step_id: 'wait', started_at: Time.current,
                        rule_snapshot: rule.steps, variables: {})
  end

  describe 'wait_for_reply' do
    let(:step) do
      { 'id' => 'wait', 'type' => 'wait_for_reply',
        'config' => { 'timeout_hours' => 24, 'on_reply_branch' => 'replied', 'on_timeout_branch' => 'no_reply' } }
    end

    def call_wait
      WorkflowEngine::StepExecutors::WaitForReply.new(run: run.reload, step: step).call
    end

    # Every wake-up path clears wait_until before the step runs again.
    def wake
      run.update!(status: 'running', wait_until: nil, wait_reason: nil)
    end

    it 'takes the timeout branch once the deadline passes, even though waking cleared wait_until' do
      first = call_wait
      expect(first[:next_step_id]).to be_nil

      travel 25.hours do
        wake
        expect(call_wait[:next_step_id]).to eq('no_reply')
      end
    end

    it 'takes the reply branch for a reply that arrived during the wait' do
      call_wait

      travel 2.hours do
        run.update!(variables: run.variables.merge('reply' => { 'channel' => 'sms', 'received_at' => Time.current.iso8601 }))
        wake
        expect(call_wait[:next_step_id]).to eq('replied')
      end
    end

    it 'ignores a reply from before this wait began' do
      run.update!(variables: { 'reply' => { 'channel' => 'email', 'received_at' => 2.days.ago.iso8601 } })
      expect(call_wait[:next_step_id]).to be_nil

      travel 25.hours do
        wake
        expect(call_wait[:next_step_id]).to eq('no_reply')
      end
    end

    it 'keeps the original deadline when woken early with no reply' do
      deadline = call_wait[:wait][:until]

      travel 1.hour do
        wake
        result = call_wait
        expect(result[:next_step_id]).to be_nil
        expect(result[:wait][:until]).to be_within(1.second).of(deadline)
      end
    end
  end

  describe 'send_sms' do
    let(:outbound) do
      Communication.create!(company_id: company.id, communicable: lead, channel: 'sms', direction: 'outbound',
                            status: 'sent', body: 'Hi Tia', to_address: '+13035551212', from_address: '+17205550100')
    end

    before do
      allow(CommunicationService).to receive(:send_sms).and_return({ success: true, communication: outbound })
    end

    it 'marks the text with its run, so a reply can find the run' do
      step = { 'id' => 'sms', 'type' => 'send_sms', 'config' => { 'to' => '{{entity.phone}}', 'body' => 'Hi' } }

      WorkflowEngine::StepExecutors::SendSms.new(run: run, step: step).call

      expect(outbound.reload.workflow_run_id).to eq(run.id)
    end

    it 'hands an inbound text reply to that run' do
      outbound.update_column(:workflow_run_id, run.id)
      allow(WorkflowEngine).to receive(:handle_inbound_reply)

      Communication.create!(company_id: company.id, communicable: lead, channel: 'sms', direction: 'inbound',
                            status: 'delivered', body: 'Yes, call me', to_address: '+17205550100', from_address: '+13035551212')

      expect(WorkflowEngine).to have_received(:handle_inbound_reply).with(hash_including(workflow_run_id: run.id))
    end
  end

  describe 'add_tag' do
    it 'tags the lead' do
      step = { 'id' => 'tag', 'type' => 'add_tag', 'config' => { 'tag_names' => ['weekly-digest-email'] } }

      result = WorkflowEngine::StepExecutors::AddTag.new(run: run, step: step).call

      expect(result[:status]).to eq('success')
      tag = Tag.find_by(company_id: company.id, name: 'weekly-digest-email')
      expect(TagAssignment.exists?(tag_id: tag.id, entity_type: 'Lead', entity_id: lead.id)).to be true
    end
  end
end
