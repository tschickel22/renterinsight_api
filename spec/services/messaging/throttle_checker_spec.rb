# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Messaging::ThrottleChecker do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:user) { User.create!(email: "u-#{SecureRandom.hex(3)}@example.com", first_name: 'T', last_name: 'U', password: 'Pass1234!', company_id: company.id) }
  let(:campaign) do
    Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'L',
                     campaign_type: 'blast', from_identity_type: 'User',
                     from_identity_id: user.id, throttle_per_day: 5)
  end
  let(:step) do
    campaign.campaign_steps.create!(position: 0, channel: 'email', subject: 'x',
                                   body_blocks: [{ 'type' => 'text', 'html' => 'a' }])
  end
  let(:source) { Source.find_or_create_by!(name: 'Web') { |s| s.source_type = 'web' } }
  let(:lead) { Lead.create!(company: company, source: source, first_name: 'A', last_name: 'B', email: 'a@b.com') }
  let(:enrollment) do
    CampaignEnrollment.create!(company_id: company.id, campaign_id: campaign.id,
                               recipient_type: 'Lead', recipient_id: lead.id,
                               email_address_snapshot: 'a@b.com', status: 'pending')
  end

  def send!(campaign_record: campaign, connection_key: nil, sent_at: Time.current)
    CampaignSend.create!(company_id: company.id, campaign_id: campaign_record.id,
                         campaign_step_id: step.id, campaign_enrollment_id: enrollment.id,
                         sending_connection_key: connection_key, sent_at: sent_at)
  end

  it 'is ok when under every cap' do
    expect(described_class.new(campaign: campaign).check).to be_ok
  end

  it 'throttles when the per-campaign daily cap is reached' do
    5.times { send! }
    result = described_class.new(campaign: campaign).check
    expect(result).to be_throttled
    expect(result.reason).to eq('campaign_per_day')
  end

  it 'throttles SMS when SmsCapService raises' do
    sms_campaign = Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'S',
                                    campaign_type: 'blast', channel: 'sms',
                                    from_identity_type: 'Company', from_identity_id: company.id,
                                    throttle_per_day: 100)
    allow(SmsCapService).to receive(:check!).and_raise(SmsCapService::CapExceededError.new('over'))
    result = described_class.new(campaign: sms_campaign).check
    expect(result).to be_throttled
    expect(result.reason).to eq('sms_cap')
  end

  describe 'per-mailbox limits' do
    let(:key) { 'UserEmailConnection:99' }

    before do
      allow(Messaging::SendRateLimits).to receive(:for)
        .with(connection_key: key)
        .and_return({ 'per_minute' => 3, 'per_hour' => 10, 'per_day' => 50 })
    end

    it 'throttles on the per-minute window' do
      3.times { send!(connection_key: key) }
      result = described_class.new(campaign: campaign, connection_key: key).check
      expect(result).to be_throttled
      expect(result.reason).to eq('mailbox_per_minute')
    end

    it 'ignores sends that have aged out of the per-minute window' do
      3.times { send!(connection_key: key, sent_at: 5.minutes.ago) }
      expect(described_class.new(campaign: campaign, connection_key: key).check).to be_ok
    end

    it 'throttles on the per-hour window once the minute window has drained' do
      10.times { send!(connection_key: key, sent_at: 30.minutes.ago) }
      result = described_class.new(campaign: campaign, connection_key: key).check
      expect(result).to be_throttled
      expect(result.reason).to eq('mailbox_per_hour')
    end

    # The regression this whole change exists for: two campaigns pointed at one
    # mailbox previously each got their own budget, so the mailbox absorbed both.
    it 'counts sends from OTHER campaigns sharing the same mailbox' do
      other = Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'Other',
                               campaign_type: 'blast', from_identity_type: 'User',
                               from_identity_id: user.id, throttle_per_day: 500)
      3.times { send!(campaign_record: other, connection_key: key) }

      result = described_class.new(campaign: campaign, connection_key: key).check
      expect(result).to be_throttled
      expect(result.reason).to eq('mailbox_per_minute')
    end

    it 'does not count sends from a different mailbox' do
      3.times { send!(connection_key: 'UserEmailConnection:1234') }
      expect(described_class.new(campaign: campaign, connection_key: key).check).to be_ok
    end

    # The old code rescheduled every throttle to exactly 1.hour.from_now, turning
    # a 6-second per-minute trip into an hour of dead time.
    it 'retries a per-minute trip in about a minute, not an hour' do
      oldest = Time.current
      3.times { send!(connection_key: key, sent_at: oldest) }
      result = described_class.new(campaign: campaign, connection_key: key).check
      expect(result.retry_at).to be < 5.minutes.from_now
      expect(result.retry_at).to be > Time.current
    end
  end
end
