# frozen_string_literal: true

require 'rails_helper'

# Campaign#throttle_per_day is per campaign, so four campaigns at 500 put 2,000
# a day through shared provider accounts that AWS and Twilio judge account-wide.
# This is the ceiling above them.
#
# The cases that matter are the ones where capping would be wrong: a password
# reset must never be blocked by a marketing limit, and a dealer on their own
# Twilio is spending their own reputation, not ours.
RSpec.describe Messaging::TenantSendCap do
  let(:company) { create(:company, use_rbac_system: false) }
  let(:user) do
    User.create!(email: "cap-#{SecureRandom.hex(4)}@example.com", password: 'Password123!',
                 company: company, first_name: 'T', last_name: 'U')
  end
  let(:source) { Source.find_or_create_by!(name: 'Web') { |s| s.source_type = 'web' } }

  def campaign_for(channel)
    c = Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: "C-#{channel}",
                         campaign_type: 'blast', channel: channel, from_identity_type: 'User',
                         from_identity_id: user.id, throttle_per_day: 500)
    attrs = { position: 0, channel: channel, subject: 'Hi',
              body_blocks: [{ 'type' => 'text', 'html' => 'a' }] }
    attrs[:sms_body] = 'Hi there' if channel == 'sms'
    c.campaign_steps.create!(attrs)
    c
  end

  def send_n(count, channel:, sent_at: 1.hour.ago)
    campaign = campaign_for(channel)
    step = campaign.campaign_steps.first
    count.times do
      lead = Lead.create!(company: company, source: source, first_name: 'A', last_name: 'B',
                          email: "l-#{SecureRandom.hex(4)}@example.com")
      enrollment = CampaignEnrollment.create!(company_id: company.id, campaign_id: campaign.id,
                                              recipient_type: 'Lead', recipient_id: lead.id,
                                              email_address_snapshot: lead.email)
      CampaignSend.create!(company_id: company.id, campaign_id: campaign.id, campaign_step_id: step.id,
                           campaign_enrollment_id: enrollment.id, sent_at: sent_at)
    end
  end

  def check(channel)
    described_class.check(company: company.reload, channel: channel)
  end

  describe 'email' do
    it 'allows sending below the cap' do
      company.update!(daily_campaign_email_cap: 5)
      send_n(3, channel: 'email')

      expect(check('email')).to be_ok
    end

    it 'stops at the cap' do
      company.update!(daily_campaign_email_cap: 3)
      send_n(3, channel: 'email')

      result = check('email')
      expect(result).to be_exceeded
      expect(result.sent_today).to eq(3)
      expect(result.cap).to eq(3)
    end

    it 'counts the tenant across campaigns, not each campaign separately' do
      company.update!(daily_campaign_email_cap: 4)
      send_n(2, channel: 'email')
      send_n(2, channel: 'email') # a second campaign

      expect(check('email')).to be_exceeded
    end

    it 'does not count sends that have aged out of the rolling day' do
      company.update!(daily_campaign_email_cap: 2)
      send_n(2, channel: 'email', sent_at: 25.hours.ago)

      expect(check('email')).to be_ok
    end

    it 'does not count SMS against the email cap' do
      company.update!(daily_campaign_email_cap: 2, daily_campaign_sms_cap: 500)
      send_n(3, channel: 'sms')

      expect(check('email')).to be_ok
    end

    it 'falls back to the platform default when the tenant has no override' do
      expect(check('email').cap).to eq(described_class::DEFAULT_EMAIL_CAP)
    end

    it 'treats zero as unlimited, the way the monthly SMS limit already does' do
      company.update!(daily_campaign_email_cap: 0)
      send_n(3, channel: 'email')

      expect(check('email')).to be_ok
    end
  end

  describe 'SMS on our own Twilio' do
    it 'caps a tenant on the shared platform account' do
      company.update!(sms_provisioning_mode: 'platform', daily_campaign_sms_cap: 2)
      send_n(2, channel: 'sms')

      expect(check('sms')).to be_exceeded
    end

    it 'caps a tenant whose number we provisioned' do
      company.update!(sms_provisioning_mode: 'dedicated', daily_campaign_sms_cap: 2)
      send_n(2, channel: 'sms')

      expect(check('sms')).to be_exceeded
    end
  end

  describe 'SMS on the tenant\'s own Twilio' do
    before do
      company.update!(sms_provisioning_mode: 'platform', daily_campaign_sms_cap: 1)
      # Stored as a JSON string, which is what the app actually writes and what
      # CommunicationSettingsService parses. Assigning a Hash to this text
      # column would to_s it into Ruby inspect format that no reader can parse.
      Setting.create!(key: 'communications', scope_type: 'Company', scope_id: company.id,
                      value: { 'sms' => { 'twilioAccountSid' => 'ACtenantowned' } }.to_json)
    end

    it 'is not rationed, because it is their account and their reputation' do
      send_n(5, channel: 'sms')

      expect(check('sms')).to be_ok
    end

    it 'reports that the cap does not apply, so the admin screen can say so' do
      expect(described_class.applies_to?(company: company.reload, channel: 'sms')).to be(false)
      expect(described_class.applies_to?(company: company.reload, channel: 'email')).to be(true)
    end
  end

  describe 'a tenant with SMS switched off' do
    it 'has no SMS cap to apply' do
      company.update!(sms_provisioning_mode: 'disabled')

      expect(described_class.applies_to?(company: company.reload, channel: 'sms')).to be(false)
    end
  end
end
