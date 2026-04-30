# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Campaigns::CampaignSender do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:user)    { User.create!(email: "u-#{SecureRandom.hex(3)}@example.com", first_name: 'T', last_name: 'U', password: 'Pass1234!', company_id: company.id) }
  let(:source)  { Source.find_or_create_by!(name: 'Web') { |s| s.source_type = 'web' } }
  let(:lead) do
    Lead.create!(company: company, source: source,
                 first_name: 'Sam', last_name: 'K',
                 email: 'sam@example.com', phone: '5551234567', opt_in_sms: true)
  end

  let(:email_campaign) do
    c = Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'E',
                         campaign_type: 'blast', channel: 'email',
                         from_identity_type: 'User', from_identity_id: user.id, throttle_per_day: 100)
    c.campaign_steps.create!(position: 0, channel: 'email', subject: 'Hi {{first_name}}',
                              body_blocks: [{ 'type' => 'text', 'html' => 'Hi {{first_name}}' }])
    c
  end

  let(:sms_campaign) do
    c = Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'S',
                         campaign_type: 'blast', channel: 'sms',
                         from_identity_type: 'Company', from_identity_id: company.id, throttle_per_day: 100)
    c.campaign_steps.create!(position: 0, channel: 'sms', sms_body: 'Hello {{first_name}}')
    c
  end

  def make_email_enrollment(camp)
    CampaignEnrollment.create!(company_id: company.id, campaign_id: camp.id,
                               recipient_type: 'Lead', recipient_id: lead.id,
                               email_address_snapshot: lead.email, status: 'pending')
  end

  def make_sms_enrollment(camp)
    CampaignEnrollment.create!(company_id: company.id, campaign_id: camp.id,
                               recipient_type: 'Lead', recipient_id: lead.id,
                               sms_phone_snapshot: '+15551234567', status: 'pending')
  end

  describe '#deliver_current_step (email)' do
    let!(:user_email_conn) do
      UserEmailConnection.create!(user_id: user.id, provider: 'oauth_gmail', is_active: true,
                                   email_address: user.email, display_name: 'Test User')
    end

    before do
      allow(CommunicationService).to receive(:send_email).and_return(
        { success: true, communication: instance_double(Communication, id: 999, body: '<p>x</p>',
                                                        update_column: true) }
      )
    end

    it 'sends and advances enrollment to completed (single-step)' do
      enrollment = make_email_enrollment(email_campaign)
      result = described_class.new(enrollment: enrollment).deliver_current_step
      expect(result).to be true
      expect(enrollment.reload.status).to eq('completed')
      expect(CampaignSend.where(campaign_enrollment_id: enrollment.id).count).to eq(1)
    end

    it 'fails enrollment when email connection is missing' do
      enrollment = make_email_enrollment(email_campaign)
      user_email_conn.update!(is_active: false)
      result = described_class.new(enrollment: enrollment).deliver_current_step
      expect(result).to be false
      expect(enrollment.reload.status).to eq('failed')
      expect(enrollment.failure_reason).to eq('no_valid_email_connection')
    end

    it 'unsubscribes when contact value is suppressed' do
      enrollment = make_email_enrollment(email_campaign)
      CampaignSuppression.create!(company_id: company.id, email_address: lead.email, reason: 'unsubscribe')
      result = described_class.new(enrollment: enrollment).deliver_current_step
      expect(result).to be false
      expect(enrollment.reload.status).to eq('unsubscribed')
    end

    it 'creates a hard-bounce suppression on hard-bounce error pattern' do
      allow(CommunicationService).to receive(:send_email).and_return(
        { success: false, error: 'Recipient address rejected: User unknown in virtual mailbox table' }
      )
      enrollment = make_email_enrollment(email_campaign)
      described_class.new(enrollment: enrollment).deliver_current_step
      expect(enrollment.reload.status).to eq('bounced')
      expect(CampaignSuppression.where(company_id: company.id, email_address: lead.email, reason: 'bounce_hard').exists?).to be true
    end
  end

  describe '#deliver_current_step (sms)' do
    let!(:twilio_acct) do
      TwilioAccount.create!(company_id: company.id, phone_number: '+15558889999',
                            phone_number_sid: 'PN1', status: 'active')
    end

    before do
      allow(TwilioSmsService).to receive(:master_credentials).and_return(['ACX', 'authtoken'])
      allow(TwilioSmsService).to receive(:master_messaging_service_sid).and_return('MGabc')
    end

    it 'sends SMS and never falls back to send_via_master' do
      expect(TwilioSmsService).not_to receive(:send_via_master)
      allow(TwilioSmsService).to receive(:send).and_return({ success: true, message_sid: 'SM1' })
      enrollment = make_sms_enrollment(sms_campaign)
      result = described_class.new(enrollment: enrollment).deliver_current_step
      expect(result).to be true
      expect(SmsUsageLog.where(company_id: company.id, source: 'campaign').count).to eq(1)
    end

    it 'fails when no TwilioAccount is active' do
      twilio_acct.update!(status: 'suspended')
      enrollment = make_sms_enrollment(sms_campaign)
      result = described_class.new(enrollment: enrollment).deliver_current_step
      expect(result).to be false
      expect(enrollment.reload.failure_reason).to eq('no_valid_sms_sender')
    end

    it 'creates an sms_stop suppression on Twilio code 21610' do
      allow(TwilioSmsService).to receive(:send).and_return(
        { success: false, error: 'Recipient has unsubscribed', twilio_code: '21610' }
      )
      enrollment = make_sms_enrollment(sms_campaign)
      described_class.new(enrollment: enrollment).deliver_current_step
      expect(enrollment.reload.status).to eq('unsubscribed')
      expect(CampaignSuppression.where(company_id: company.id, reason: 'sms_stop').exists?).to be true
    end
  end
end
