# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Campaigns::ReplyHandler do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:user)    { User.create!(email: "u-#{SecureRandom.hex(3)}@example.com", first_name: 'T', last_name: 'U', password: 'Pass1234!', company_id: company.id) }
  let(:source)  { Source.find_or_create_by!(name: 'Web') { |s| s.source_type = 'web' } }
  let(:lead)    { Lead.create!(company: company, source: source, first_name: 'A', last_name: 'B', email: 'a@b.com') }
  let(:campaign) do
    Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'C',
                     campaign_type: 'blast', from_identity_type: 'User', from_identity_id: user.id,
                     throttle_per_day: 100, goal_config: { 'primary_goal' => 'replied' })
  end
  let(:step) { campaign.campaign_steps.create!(position: 0, channel: 'email', subject: 'Hi', body_blocks: [{ 'type' => 'text', 'html' => 'x' }]) }
  let(:enrollment) do
    CampaignEnrollment.create!(company_id: company.id, campaign_id: campaign.id,
                               recipient_type: 'Lead', recipient_id: lead.id,
                               email_address_snapshot: lead.email, status: 'active')
  end
  let(:campaign_send) do
    CampaignSend.create!(company_id: company.id, campaign_id: campaign.id,
                         campaign_step_id: step.id, campaign_enrollment_id: enrollment.id,
                         sent_at: 1.hour.ago)
  end

  def parsed(extra = {})
    {
      from: 'a@b.com', to: 'reply+campaign-x@mail.test',
      subject: 'Re: hi', body_text: 'thanks!', headers: '',
      timestamp: Time.current
    }.merge(extra)
  end

  it 'returns handled=false for unknown send_id' do
    result = described_class.process(token: 'campaign-99999999', parsed_email: parsed)
    expect(result.handled).to be false
  end

  it 'marks enrollment goal_met when replied is the primary goal' do
    cs = campaign_send
    described_class.process(token: "campaign-#{cs.id}", parsed_email: parsed)
    expect(enrollment.reload.status).to eq('goal_met')
    expect(cs.reload.replied_at).not_to be_nil
  end

  it 'pauses enrollment when replied is NOT a goal' do
    campaign.update!(goal_config: { 'primary_goal' => 'opened' })
    cs = campaign_send
    described_class.process(token: "campaign-#{cs.id}", parsed_email: parsed)
    expect(enrollment.reload.status).to eq('paused')
  end

  it 'detects out-of-office replies and does not change enrollment status' do
    cs = campaign_send
    described_class.process(token: "campaign-#{cs.id}",
                              parsed_email: parsed(subject: 'Out of office: Vacation'))
    expect(enrollment.reload.status).to eq('active')
    expect(cs.reload.replied_at).to be_nil
  end
end
