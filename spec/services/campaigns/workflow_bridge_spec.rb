# frozen_string_literal: true

require 'rails_helper'

# Campaign engagement used to stop at campaign_sends. These cover each path
# now reaching the workflow engine, once per send, on the recipient.
RSpec.describe Campaigns::WorkflowBridge do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:user)    { User.create!(email: "u-#{SecureRandom.hex(3)}@example.com", first_name: 'T', last_name: 'U', password: 'Pass1234!', company_id: company.id) }
  let(:source)  { Source.find_or_create_by!(name: 'Web') { |s| s.source_type = 'web' } }
  let(:lead)    { Lead.create!(company: company, source: source, first_name: 'Sam', last_name: 'K', email: 'sam@example.com') }

  let(:campaign) do
    c = Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'Spring homes',
                         campaign_type: 'blast', channel: 'email', status: 'running',
                         from_identity_type: 'User', from_identity_id: user.id, throttle_per_day: 100)
    c.campaign_steps.create!(position: 0, channel: 'email', subject: 'Homes', body_blocks: [{ 'type' => 'text', 'html' => 'a' }])
    c
  end

  let(:enrollment) do
    CampaignEnrollment.create!(company_id: company.id, campaign_id: campaign.id, recipient_type: 'Lead',
                               recipient_id: lead.id, email_address_snapshot: lead.email, status: 'active')
  end

  let(:communication) do
    Communication.create!(company_id: company.id, communicable: lead, channel: 'email', direction: 'outbound',
                          status: 'sent', subject: 'Homes', body: '<p>a</p>', to_address: lead.email,
                          from_address: user.email)
  end

  let(:send_record) do
    CampaignSend.create!(company_id: company.id, campaign_id: campaign.id, campaign_step_id: campaign.campaign_steps.first.id,
                         campaign_enrollment_id: enrollment.id, communication_id: communication.id, sent_at: 1.hour.ago)
  end

  def events(type)
    WorkflowEvent.where(company_id: company.id, event_type: type, entity_type: 'Lead', entity_id: lead.id)
  end

  it 'emits campaign.opened on the first open only' do
    send_record
    2.times { CampaignSend.record_open_for_communication(communication.id) }

    expect(events('campaign.opened').count).to eq(1)
    expect(events('campaign.opened').last.payload).to include('campaign_id' => campaign.id, 'campaign_send_id' => send_record.id)
    expect(send_record.reload.open_count).to eq(2)
  end

  it 'emits campaign.clicked once with the link, and counts the implied open' do
    2.times { CampaignSend.record_click_for_send(send_record, url: 'https://dealer.example/homes/42') }

    expect(events('campaign.clicked').count).to eq(1)
    expect(events('campaign.clicked').last.payload['url']).to eq('https://dealer.example/homes/42')
    expect(events('campaign.opened').count).to eq(1)
    expect(send_record.reload.click_count).to eq(2)
  end

  it 'emits campaign.replied when the prospect replies' do
    Campaigns::ReplyHandler.process(
      token: "campaign-#{send_record.id}",
      parsed_email: { from: lead.email, to: 'reply@example.com', subject: 'Re: Homes', body_text: 'Is lot 42 still there?', headers: '' }
    )

    expect(events('campaign.replied').count).to eq(1)
  end

  it 'emits campaign.bounced with the bounce type' do
    send_record.update!(bounced_at: Time.current, bounce_type: 'hard')

    expect(events('campaign.bounced').last.payload['bounce_type']).to eq('hard')
  end

  it 'emits campaign.unsubscribed when the enrollment unsubscribes' do
    enrollment.update!(status: 'unsubscribed', unsubscribed_at: Time.current)

    expect(events('campaign.unsubscribed').count).to eq(1)
  end

  it 'emits nothing for a test send' do
    enrollment.update!(metadata: { 'test_send' => 'true' })

    CampaignSend.record_click_for_send(send_record, url: 'https://dealer.example')

    expect(WorkflowEvent.where(company_id: company.id).where("event_type LIKE 'campaign.%'")).to be_empty
  end

  it 'starts a rule scoped to its own campaign only' do
    rule = WorkflowRule.create!(
      company_id: company.id, name: 'Clicked, call them', entity_type: 'Lead', status: 'active',
      trigger: { 'event_type' => 'campaign.clicked' },
      conditions: { 'type' => 'and', 'children' => [
        { 'field' => 'trigger.campaign_id', 'operator' => 'equals', 'value' => campaign.id }
      ] },
      steps: { 'nodes' => [{ 'id' => 'n1', 'type' => 'wait', 'config' => { 'duration' => 1 } }] }
    )
    other = Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'Other',
                             campaign_type: 'blast', channel: 'email', status: 'running',
                             from_identity_type: 'User', from_identity_id: user.id, throttle_per_day: 100)
    other_step = other.campaign_steps.create!(position: 0, channel: 'email', subject: 'X', body_blocks: [{ 'type' => 'text', 'html' => 'a' }])
    other_lead = Lead.create!(company: company, source: source, first_name: 'Jo', last_name: 'P', email: 'jo@example.com')
    other_enrollment = CampaignEnrollment.create!(company_id: company.id, campaign_id: other.id, recipient_type: 'Lead',
                                                  recipient_id: other_lead.id, email_address_snapshot: other_lead.email, status: 'active')
    other_send = CampaignSend.create!(company_id: company.id, campaign_id: other.id, campaign_step_id: other_step.id,
                                      campaign_enrollment_id: other_enrollment.id, sent_at: 1.hour.ago)

    CampaignSend.record_click_for_send(send_record, url: 'https://dealer.example/a')
    CampaignSend.record_click_for_send(other_send, url: 'https://dealer.example/b')
    DispatchWorkflowEventsJob.new.perform

    expect(WorkflowRun.where(workflow_rule_id: rule.id).pluck(:entity_id)).to eq([lead.id])
  end
end
