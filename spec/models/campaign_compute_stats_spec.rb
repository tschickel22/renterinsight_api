# frozen_string_literal: true

require 'rails_helper'

# The Overview tab and the Recipients tab disagreed: Overview read a copy made
# up to 15 minutes earlier, counted emails rather than people, and divided opens
# by every message including texts.
RSpec.describe Campaign, '#compute_stats' do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:campaign) do
    Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'C', campaign_type: 'drip',
                     status: 'running', from_identity_type: 'User', from_identity_id: user.id, throttle_per_day: 100)
  end
  let(:email1) { campaign.campaign_steps.create!(position: 0, channel: 'email', body_blocks: [{ 'type' => 'text', 'html' => 'x' }]) }
  let(:email2) { campaign.campaign_steps.create!(position: 1, channel: 'email', body_blocks: [{ 'type' => 'text', 'html' => 'y' }]) }
  let(:text) { campaign.campaign_steps.create!(position: 2, channel: 'sms', sms_body: 'Hi') }

  def person
    lead = Lead.create!(company: company, first_name: 'B', last_name: SecureRandom.hex(2), email: "b-#{SecureRandom.hex(4)}@example.com")
    CampaignEnrollment.create!(company_id: company.id, campaign_id: campaign.id, recipient_type: 'Lead',
                               recipient_id: lead.id, email_address_snapshot: lead.email)
  end

  def sent(enrollment, step, **attrs)
    CampaignSend.create!(company_id: company.id, campaign_id: campaign.id, campaign_step_id: step.id,
                         campaign_enrollment_id: enrollment.id, sent_at: 1.hour.ago, **attrs)
  end

  it 'counts emails and people separately, and leaves texts out of email totals' do
    a = person
    b = person
    sent(a, email1, opened_at: 1.minute.ago, clicked_at: 1.minute.ago)
    sent(a, email2, opened_at: 1.minute.ago)
    sent(a, text)
    sent(b, email1)

    stats = campaign.compute_stats
    expect(stats).to include('total_sent' => 4, 'emails_sent' => 3, 'opened' => 2, 'clicked' => 1,
                             'recipients' => 2, 'people_opened' => 1, 'people_clicked' => 1)
  end

  it 'refreshes a copy more than a minute old and keeps a fresh one' do
    sent(person, email1, opened_at: 1.minute.ago)
    campaign.update_column(:stats_cache, { 'opened' => 0, 'updated_at' => 10.seconds.ago.iso8601 })
    expect(campaign.refresh_stats!['opened']).to eq(0)

    campaign.update_column(:stats_cache, { 'opened' => 0, 'updated_at' => 5.minutes.ago.iso8601 })
    expect(campaign.refresh_stats!['opened']).to eq(1)
  end
end
