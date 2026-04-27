# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Campaigns::AudienceEnroller do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:user)    { User.create!(email: "u-#{SecureRandom.hex(3)}@example.com", first_name: 'T', last_name: 'U', password: 'Pass1234!', company_id: company.id) }
  let(:source)  { Source.find_or_create_by!(name: 'Web') { |s| s.source_type = 'web' } }

  let!(:lead_a) { Lead.create!(company: company, source: source, first_name: 'A', last_name: '1', email: 'a@x.com', opt_in_sms: true) }
  let!(:lead_b) { Lead.create!(company: company, source: source, first_name: 'B', last_name: '2', email: 'b@x.com', opt_in_sms: true) }

  let(:campaign) do
    c = Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'E',
                         campaign_type: 'blast', channel: 'email', audience_mode: 'static',
                         from_identity_type: 'User', from_identity_id: user.id, throttle_per_day: 100)
    c.campaign_steps.create!(position: 0, channel: 'email', subject: 'Hi',
                              body_blocks: [{ 'type' => 'text', 'html' => 'a' }],
                              wait_days: 0, wait_hours: 0)
    c.create_campaign_audience!(source_type: 'Lead', filter_tree: {})
    c
  end

  it 'enrolls all leads when filter_tree is empty' do
    enrolled = described_class.new(campaign: campaign).enroll_all
    expect(enrolled).to eq(2)
    expect(campaign.campaign_enrollments.count).to eq(2)
  end

  it 'skips leads whose email is suppressed' do
    CampaignSuppression.create!(company_id: company.id, email_address: lead_a.email, reason: 'unsubscribe')
    enrolled = described_class.new(campaign: campaign).enroll_all
    expect(enrolled).to eq(1)
    expect(campaign.campaign_enrollments.pluck(:recipient_id)).to contain_exactly(lead_b.id)
  end

  it 'snapshots audience for static mode on first enrollment' do
    expect(campaign.audience_snapshot_at).to be_nil
    described_class.new(campaign: campaign).enroll_all
    expect(campaign.reload.audience_snapshot_at).not_to be_nil
  end

  it 'is idempotent: re-running does not create duplicates' do
    described_class.new(campaign: campaign).enroll_all
    second = described_class.new(campaign: campaign).enroll_all
    expect(second).to eq(0)
    expect(campaign.campaign_enrollments.count).to eq(2)
  end
end
