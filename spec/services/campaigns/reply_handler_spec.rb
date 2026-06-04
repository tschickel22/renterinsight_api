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

  it 'records the conversion but keeps sending when replied goal defaults to track' do
    cs = campaign_send
    described_class.process(token: "campaign-#{cs.id}", parsed_email: parsed)
    enrollment.reload
    # 'track' (default): conversion recorded, but the contact stays in the campaign.
    expect(enrollment.status).to eq('active')
    expect(enrollment.goal_met_at).to be_present
    expect(enrollment.goal_met_reason).to eq('replied')
    expect(cs.reload.replied_at).not_to be_nil
  end

  it 'marks enrollment goal_met when replied goal action is stop' do
    campaign.update!(goal_config: { 'primary_goal' => 'replied', 'goal_actions' => { 'replied' => 'stop' } })
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

  it 'stamps opened_at on a genuine reply (a reply implies an open)' do
    cs = campaign_send
    expect(cs.opened_at).to be_nil
    described_class.process(token: "campaign-#{cs.id}", parsed_email: parsed)
    cs.reload
    expect(cs.opened_at).to be_present
    expect(cs.open_count).to be >= 1
  end

  it 'does not stamp opened_at on an out-of-office reply' do
    cs = campaign_send
    described_class.process(token: "campaign-#{cs.id}", parsed_email: parsed(subject: 'Automatic reply'))
    expect(cs.reload.opened_at).to be_nil
  end

  it 'notifies the original sender of the campaign email on a genuine reply' do
    sender = User.create!(email: "snd-#{SecureRandom.hex(3)}@example.com", first_name: 'Snd', last_name: 'R', password: 'Pass1234!', company_id: company.id)
    comm = Communication.create!(company_id: company.id, communicable: lead, channel: 'email', direction: 'outbound',
                                 subject: 'Hi', body: 'b', from_address: 'r@e.com', to_address: lead.email,
                                 status: 'sent', metadata: { 'sender_user_id' => sender.id })
    cs = campaign_send
    cs.update_columns(communication_id: comm.id)
    expect {
      described_class.process(token: "campaign-#{cs.id}", parsed_email: parsed)
    }.to change {
      Notification.where(recipient_id: sender.id, recipient_type: 'User', notification_type: 'email_reply_received').count
    }.by(1)
  end

  it 'does not notify on an out-of-office reply' do
    cs = campaign_send
    expect {
      described_class.process(token: "campaign-#{cs.id}", parsed_email: parsed(subject: 'Automatic reply'))
    }.not_to change { Notification.where(notification_type: 'email_reply_received').count }
  end
end
