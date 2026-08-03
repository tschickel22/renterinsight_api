# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Ses::EventProcessor do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(3)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id)
  end
  let(:source) { Source.find_or_create_by!(name: 'Web') { |s| s.source_type = 'web' } }
  let!(:lead) do
    Lead.create!(company: company, source: source, first_name: 'A', last_name: '1', email: 'a@x.com')
  end

  let(:campaign) do
    c = Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'E',
                         campaign_type: 'blast', channel: 'email', audience_mode: 'static',
                         from_identity_type: 'User', from_identity_id: user.id, throttle_per_day: 500)
    c.campaign_steps.create!(position: 0, channel: 'email', subject: 'Hi',
                             body_blocks: [{ 'type' => 'text', 'html' => 'a' }],
                             wait_days: 0, wait_hours: 0)
    c
  end

  let(:step) { campaign.campaign_steps.first }

  let(:enrollment) do
    CampaignEnrollment.create!(
      company_id: company.id, campaign_id: campaign.id, recipient_type: 'Lead',
      recipient_id: lead.id, status: 'active', current_step_index: 0,
      email_address_snapshot: lead.email, next_send_at: Time.current
    )
  end

  let(:communication) do
    Communication.create!(
      company_id: company.id, channel: 'email', direction: 'outbound',
      subject: 'Hi', body: 'a', to_address: lead.email, from_address: 'sender@example.com', status: 'sent',
      external_id: ses_message_id
    )
  end

  let(:ses_message_id) { "0100018f-#{SecureRandom.hex(6)}" }

  let!(:campaign_send) do
    CampaignSend.create!(
      company_id: company.id, campaign_id: campaign.id, campaign_step_id: step.id,
      campaign_enrollment_id: enrollment.id, communication_id: communication.id,
      sent_at: Time.current
    )
  end

  def event(type, extra = {})
    { 'eventType' => type, 'mail' => { 'messageId' => ses_message_id } }.merge(extra)
  end

  describe 'Delivery' do
    it 'stamps delivered_at on the send and the communication' do
      result = described_class.process(event('Delivery'))

      expect(result.handled).to be true
      expect(campaign_send.reload.delivered_at).to be_present
      expect(communication.reload.delivered_at).to be_present
    end

    it 'records a delivered campaign event' do
      described_class.process(event('Delivery'))

      expect(CampaignEvent.where(campaign_send_id: campaign_send.id, event_type: 'delivered').count).to eq(1)
    end

    it 'is idempotent when SNS redelivers the same notification' do
      described_class.process(event('Delivery'))
      first_stamp = campaign_send.reload.delivered_at

      described_class.process(event('Delivery'))

      expect(campaign_send.reload.delivered_at).to eq(first_stamp)
      expect(CampaignEvent.where(campaign_send_id: campaign_send.id, event_type: 'delivered').count).to eq(1)
    end
  end

  describe 'Bounce' do
    let(:permanent) do
      event('Bounce', 'bounce' => {
        'bounceType' => 'Permanent', 'bounceSubType' => 'General',
        'bouncedRecipients' => [{ 'emailAddress' => lead.email, 'diagnosticCode' => '550 5.1.1 user unknown' }]
      })
    end

    let(:transient) do
      event('Bounce', 'bounce' => {
        'bounceType' => 'Transient', 'bounceSubType' => 'MailboxFull',
        'bouncedRecipients' => [{ 'emailAddress' => lead.email }]
      })
    end

    it 'marks a permanent bounce hard and suppresses the address' do
      described_class.process(permanent)

      expect(campaign_send.reload.bounce_type).to eq('hard')
      expect(campaign_send.bounced_at).to be_present
      expect(CampaignSuppression.find_by(company_id: company.id, email_address: lead.email).reason).to eq('bounce_hard')
      expect(enrollment.reload.status).to eq('bounced')
    end

    it 'flags the recipient as email_invalid on a hard bounce' do
      described_class.process(permanent)

      expect(lead.reload.email_invalid).to be true
    end

    it 'marks a transient bounce soft and does not suppress' do
      described_class.process(transient)

      expect(campaign_send.reload.bounce_type).to eq('soft')
      expect(CampaignSuppression.where(company_id: company.id, email_address: lead.email)).to be_empty
      expect(enrollment.reload.status).not_to eq('bounced')
    end

    it 'counts soft bounces and fails the enrollment on the third' do
      3.times do
        campaign_send.update_columns(bounced_at: nil, bounce_type: nil)
        described_class.process(transient)
      end

      expect(enrollment.reload.status).to eq('failed')
      expect(enrollment.metadata['retry_count']).to eq(3)
    end

    it 'treats an undetermined bounce as soft rather than suppressing on a guess' do
      described_class.process(event('Bounce', 'bounce' => { 'bounceType' => 'Undetermined' }))

      expect(campaign_send.reload.bounce_type).to eq('soft')
      expect(CampaignSuppression.where(company_id: company.id, email_address: lead.email)).to be_empty
    end
  end

  describe 'Complaint' do
    let(:complaint) do
      event('Complaint', 'complaint' => { 'complaintFeedbackType' => 'abuse' })
    end

    it 'suppresses the address and unsubscribes the enrollment' do
      described_class.process(complaint)

      expect(CampaignSuppression.find_by(company_id: company.id, email_address: lead.email).reason).to eq('complaint')
      expect(enrollment.reload.status).to eq('unsubscribed')
    end

    it 'suppresses even when the send already bounced' do
      campaign_send.update!(bounced_at: Time.current, bounce_type: 'soft')

      described_class.process(complaint)

      expect(CampaignSuppression.find_by(company_id: company.id, email_address: lead.email)).to be_present
    end
  end

  describe 'unmatched messages' do
    it 'ignores an event whose message id matches no communication' do
      result = described_class.process(
        'eventType' => 'Delivery', 'mail' => { 'messageId' => 'unknown-id' }
      )

      expect(result.handled).to be false
      expect(campaign_send.reload.delivered_at).to be_nil
    end

    it 'accepts the older notificationType shape as well as eventType' do
      result = described_class.process(
        'notificationType' => 'Delivery', 'mail' => { 'messageId' => ses_message_id }
      )

      expect(result.handled).to be true
      expect(campaign_send.reload.delivered_at).to be_present
    end

    it 'parses a JSON string payload' do
      result = described_class.process(event('Delivery').to_json)

      expect(result.handled).to be true
    end
  end
end
