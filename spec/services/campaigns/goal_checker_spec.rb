# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Campaigns::GoalChecker do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:user)    { User.create!(email: "u-#{SecureRandom.hex(3)}@example.com", first_name: 'T', last_name: 'U', password: 'Pass1234!', company_id: company.id) }
  let(:source)  { Source.find_or_create_by!(name: 'Web') { |s| s.source_type = 'web' } }
  let(:lead)    { Lead.create!(company: company, source: source, first_name: 'A', last_name: 'B', email: 'a@b.com') }

  let(:campaign) do
    c = Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'C',
                         campaign_type: 'blast', from_identity_type: 'User', from_identity_id: user.id,
                         throttle_per_day: 100, goal_config: { 'primary_goal' => 'opened' })
    c.campaign_steps.create!(position: 0, channel: 'email', subject: 'Hi', body_blocks: [{ 'type' => 'text', 'html' => 'x' }])
    c
  end

  let(:enrollment) do
    CampaignEnrollment.create!(company_id: company.id, campaign_id: campaign.id,
                               recipient_type: 'Lead', recipient_id: lead.id,
                               email_address_snapshot: lead.email, status: 'active')
  end

  def add_opened_send
    step = campaign.campaign_steps.first
    CampaignSend.create!(company_id: company.id, campaign_id: campaign.id,
                         campaign_step_id: step.id, campaign_enrollment_id: enrollment.id,
                         sent_at: 1.hour.ago, opened_at: 30.minutes.ago)
  end

  it 'records the conversion but keeps sending when the goal action defaults to track' do
    add_opened_send
    described_class.new(campaign: campaign).run
    enrollment.reload
    # 'track' (default) records goal_met_at + reason for analytics but leaves the
    # enrollment in an active status so the campaign keeps sending.
    expect(enrollment.status).to eq('active')
    expect(enrollment.goal_met_at).to be_present
    expect(enrollment.goal_met_reason).to eq('opened')
  end

  it 'stops sending to the contact when the goal action is stop' do
    campaign.update!(goal_config: { 'primary_goal' => 'opened', 'goal_actions' => { 'opened' => 'stop' } })
    add_opened_send
    described_class.new(campaign: campaign).run
    enrollment.reload
    expect(enrollment.status).to eq('goal_met')
    expect(enrollment.goal_met_reason).to eq('opened')
  end

  it 'does not re-fire on a subsequent run once the conversion is recorded (track)' do
    add_opened_send
    described_class.new(campaign: campaign).run
    # Already converted (goal_met_at set) — a second pass must not create a duplicate event.
    expect { described_class.new(campaign: campaign).run }
      .not_to change { CampaignEvent.where(event_type: 'goal_met', campaign_enrollment_id: enrollment.id).count }
  end

  it 'does not mark goal_met when no qualifying event exists' do
    described_class.new(campaign: campaign).run
    expect(enrollment.reload.status).to eq('active')
    expect(enrollment.reload.goal_met_at).to be_nil
  end

  it 'returns 0 when goal_config is empty' do
    campaign.update!(goal_config: {})
    expect(described_class.new(campaign: campaign).run).to eq(0)
  end
end
