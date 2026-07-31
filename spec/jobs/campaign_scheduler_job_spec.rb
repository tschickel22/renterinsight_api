# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CampaignSchedulerJob do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:user)    { User.create!(email: "u-#{SecureRandom.hex(3)}@example.com", first_name: 'T', last_name: 'U', password: 'Pass1234!', company_id: company.id) }

  it 'promotes scheduled campaigns to running and enqueues enroller' do
    campaign = Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'L',
                                campaign_type: 'blast', from_identity_type: 'User', from_identity_id: user.id,
                                throttle_per_day: 100, status: 'scheduled', scheduled_at: 1.minute.ago)

    expect { described_class.perform_now }.to have_enqueued_job(CampaignAudienceEnrollerJob).with(campaign.id).at_least(:once)
    expect(campaign.reload.status).to eq('running')
  end

  it 'dispatches due-for-send enrollments' do
    campaign = Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'L2',
                                campaign_type: 'blast', from_identity_type: 'User', from_identity_id: user.id,
                                throttle_per_day: 100, status: 'running')
    campaign.campaign_steps.create!(position: 0, channel: 'email', subject: 'Hi', body_blocks: [{ 'type' => 'text', 'html' => 'a' }])
    source = Source.find_or_create_by!(name: 'Web') { |s| s.source_type = 'web' }
    lead = Lead.create!(company: company, source: source, first_name: 'A', last_name: 'B', email: 'a@b.com')
    enrollment = CampaignEnrollment.create!(company_id: company.id, campaign_id: campaign.id,
                                             recipient_type: 'Lead', recipient_id: lead.id,
                                             email_address_snapshot: 'a@b.com',
                                             status: 'active', next_send_at: 1.minute.ago)

    expect { described_class.perform_now }.to have_enqueued_job(ProcessCampaignSendJob).with(enrollment.id)
  end

  # Regression: a running dynamic campaign that already had enrollments never
  # re-enrolled, so widening its audience showed new recipients on screen who
  # never received a step.
  it 're-enrolls running dynamic campaigns that already have enrollments' do
    campaign = Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'Dyn',
                                campaign_type: 'drip', from_identity_type: 'User', from_identity_id: user.id,
                                throttle_per_day: 100, status: 'running', audience_mode: 'dynamic')
    source = Source.find_or_create_by!(name: 'Web') { |s| s.source_type = 'web' }
    lead = Lead.create!(company: company, source: source, first_name: 'C', last_name: 'D', email: 'c@d.com')
    CampaignEnrollment.create!(company_id: company.id, campaign_id: campaign.id,
                               recipient_type: 'Lead', recipient_id: lead.id,
                               email_address_snapshot: 'c@d.com',
                               status: 'active', next_send_at: 1.day.from_now)

    expect { described_class.perform_now }.to have_enqueued_job(CampaignAudienceEnrollerJob).with(campaign.id)
  end

  it 'does not re-enroll running static campaigns that already have enrollments' do
    campaign = Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'Stat',
                                campaign_type: 'drip', from_identity_type: 'User', from_identity_id: user.id,
                                throttle_per_day: 100, status: 'running', audience_mode: 'static')
    source = Source.find_or_create_by!(name: 'Web') { |s| s.source_type = 'web' }
    lead = Lead.create!(company: company, source: source, first_name: 'E', last_name: 'F', email: 'e@f.com')
    CampaignEnrollment.create!(company_id: company.id, campaign_id: campaign.id,
                               recipient_type: 'Lead', recipient_id: lead.id,
                               email_address_snapshot: 'e@f.com',
                               status: 'active', next_send_at: 1.day.from_now)

    expect { described_class.perform_now }.not_to have_enqueued_job(CampaignAudienceEnrollerJob).with(campaign.id)
  end
end
