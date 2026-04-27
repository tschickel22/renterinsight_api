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

  it 'returns :ok when under daily cap' do
    expect(described_class.new(campaign: campaign).check).to eq(:ok)
  end

  it 'returns :throttled when daily cap reached' do
    step = campaign.campaign_steps.create!(position: 0, channel: 'email', subject: 'x', body_blocks: [{ 'type' => 'text', 'html' => 'a' }])
    source = Source.find_or_create_by!(name: 'Web') { |s| s.source_type = 'web' }
    lead = Lead.create!(company: company, source: source, first_name: 'A', last_name: 'B', email: 'a@b.com')
    enrollment = CampaignEnrollment.create!(company_id: company.id, campaign_id: campaign.id,
                                            recipient_type: 'Lead', recipient_id: lead.id,
                                            email_address_snapshot: 'a@b.com', status: 'pending')
    5.times do
      CampaignSend.create!(company_id: company.id, campaign_id: campaign.id, campaign_step_id: step.id,
                           campaign_enrollment_id: enrollment.id, sent_at: Time.current)
    end
    expect(described_class.new(campaign: campaign).check).to eq(:throttled)
  end

  it 'returns :throttled for SMS when SmsCapService raises' do
    sms_campaign = Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'S',
                                    campaign_type: 'blast', channel: 'sms',
                                    from_identity_type: 'Company', from_identity_id: company.id, throttle_per_day: 100)
    allow(SmsCapService).to receive(:check!).and_raise(SmsCapService::CapExceededError.new('over'))
    expect(described_class.new(campaign: sms_campaign).check).to eq(:throttled)
  end
end
