# frozen_string_literal: true

require 'rails_helper'

# An email campaign carrying SMS steps. Enrollment used to snapshot only the
# campaign channel's address, so every SMS step found no phone and failed the
# enrollment, and SMS steps skipped the opt-in check the audience applies to an
# SMS campaign.
RSpec.describe 'Mixed email and SMS campaigns' do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:user)    { User.create!(email: "u-#{SecureRandom.hex(3)}@example.com", first_name: 'T', last_name: 'U', password: 'Pass1234!', company_id: company.id) }
  let(:source)  { Source.find_or_create_by!(name: 'Web') { |s| s.source_type = 'web' } }

  let(:campaign) do
    c = Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'Mixed',
                         campaign_type: 'drip', channel: 'email', audience_mode: 'static',
                         from_identity_type: 'User', from_identity_id: user.id, throttle_per_day: 100)
    c.campaign_steps.create!(position: 0, channel: 'email', subject: 'Hi',
                             body_blocks: [{ 'type' => 'text', 'html' => 'Hi {{first_name}}' }])
    c.campaign_steps.create!(position: 1, channel: 'sms', sms_body: 'Quick check in, {{first_name}}', wait_days: 2)
    c.create_campaign_audience!(source_type: 'Lead', filter_tree: {})
    c
  end

  def lead(attrs = {})
    Lead.create!({ company: company, source: source, first_name: 'Sam', last_name: 'K' }.merge(attrs))
  end

  describe Campaigns::AudienceEnroller do
    it 'snapshots both the email and the phone' do
      l = lead(email: 'Sam@Example.com', phone: '5551234567')
      described_class.new(campaign: campaign).enroll_all
      e = campaign.campaign_enrollments.find_by(recipient_id: l.id)
      expect(e.email_address_snapshot).to eq('sam@example.com')
      expect(e.sms_phone_snapshot).to eq('+15551234567')
    end

    # The audience of an email-led campaign is email-reachable people, the
    # same rule the audience counts on screen use.
    it 'leaves out someone with only a phone' do
      l = lead(phone: '5551234567')
      described_class.new(campaign: campaign).enroll_all
      expect(campaign.campaign_enrollments.find_by(recipient_id: l.id)).to be_nil
    end

    it 'leaves the phone off an email-only campaign' do
      campaign.campaign_steps.find_by(position: 1).destroy!
      l = lead(email: 'sam@example.com', phone: '5551234567')
      described_class.new(campaign: campaign).enroll_all
      expect(campaign.campaign_enrollments.find_by(recipient_id: l.id).sms_phone_snapshot).to be_nil
    end
  end

  describe Campaigns::CampaignSender do
    let!(:twilio_acct) do
      TwilioAccount.create!(company_id: company.id, phone_number: '+15558889999',
                            phone_number_sid: 'PN1', status: 'active')
    end

    before do
      Setting.set('Company', company.id, 'require_marketing_consent', false)
      allow(TwilioSmsService).to receive(:master_credentials).and_return(%w[ACX authtoken])
      allow(TwilioSmsService).to receive(:master_messaging_service_sid).and_return('MGabc')
      allow(TwilioSmsService).to receive(:send).and_return({ success: true, message_sid: 'SM1' })
    end

    def at_sms_step(recipient, phone: '+15551234567')
      CampaignEnrollment.create!(company_id: company.id, campaign_id: campaign.id,
                                 recipient_type: 'Lead', recipient_id: recipient.id,
                                 email_address_snapshot: recipient.email, sms_phone_snapshot: phone,
                                 status: 'active', current_step_index: 1)
    end

    it 'texts an opted-in recipient' do
      e = at_sms_step(lead(email: 'a@x.com', phone: '5551234567', opt_in_sms: true))
      expect(described_class.new(enrollment: e).deliver_current_step).to be true
      expect(TwilioSmsService).to have_received(:send)
    end

    it 'skips the text for someone who did not opt in to SMS' do
      e = at_sms_step(lead(email: 'a@x.com', phone: '5551234567', opt_in_sms: false))
      sender = described_class.new(enrollment: e)
      expect(sender.deliver_current_step).to be false
      expect(sender.last_skip_reason).to eq('no_sms_opt_in')
      expect(TwilioSmsService).not_to have_received(:send)
    end

    it 'texts them once written consent is acknowledged' do
      audience = campaign.campaign_audience
      audience.update!(metadata: { 'compliance_override_acknowledged' => 'true' })
      e = at_sms_step(lead(email: 'a@x.com', phone: '5551234567', opt_in_sms: false))
      expect(described_class.new(enrollment: e).deliver_current_step).to be true
    end

    it 'skips the text, without failing the enrollment, for someone with no phone' do
      e = at_sms_step(lead(email: 'a@x.com', opt_in_sms: true), phone: nil)
      sender = described_class.new(enrollment: e)
      expect(sender.deliver_current_step).to be false
      expect(sender.last_skip_reason).to eq('no_sms_address')
      expect(e.reload.status).not_to eq('failed')
    end
  end
end
