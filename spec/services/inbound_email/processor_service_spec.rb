# frozen_string_literal: true

require 'rails_helper'

RSpec.describe InboundEmail::ProcessorService do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:user)    { User.create!(email: "u-#{SecureRandom.hex(3)}@example.com", first_name: 'T', last_name: 'U', password: 'Pass1234!', company_id: company.id) }
  let(:source)  { Source.find_or_create_by!(name: 'Web') { |s| s.source_type = 'web' } }
  let(:lead)    { Lead.create!(company: company, source: source, first_name: 'A', last_name: 'B', email: 'recipient@example.com') }

  let(:campaign) do
    c = Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'P',
                         campaign_type: 'blast', from_identity_type: 'User', from_identity_id: user.id,
                         throttle_per_day: 100,
                         goal_config: { 'primary_goal' => 'replied' })
    c.campaign_steps.create!(position: 0, channel: 'email', subject: 'Hi',
                             body_blocks: [{ 'type' => 'text', 'html' => 'x' }])
    c
  end
  let(:step) { campaign.campaign_steps.first }
  let(:enrollment) do
    CampaignEnrollment.create!(company_id: company.id, campaign_id: campaign.id,
                               recipient_type: 'Lead', recipient_id: lead.id,
                               email_address_snapshot: 'recipient@example.com', status: 'active')
  end
  let(:send_record) do
    CampaignSend.create!(company_id: company.id, campaign_id: campaign.id,
                         campaign_step_id: step.id, campaign_enrollment_id: enrollment.id,
                         sent_at: 2.hours.ago)
  end

  def parsed(overrides = {})
    {
      from: 'someone@example.com',
      to: "reply+campaign-#{send_record.id}@mail.renterinsight.com",
      subject: 'Re: Welcome',
      body_text: 'Thanks!',
      body_html: '<p>Thanks!</p>',
      timestamp: Time.current,
      token: { prefix: 'reply', token: "campaign-#{send_record.id}" },
      message_id: 'msg-1',
      headers: '',
      content_type: 'text/plain'
    }.merge(overrides)
  end

  it 'routes a hard-bounce inbound email to BounceHandler, not ReplyHandler' do
    email = parsed(
      from: 'mailer-daemon@mail.example.com',
      subject: 'Undeliverable: Welcome',
      body_text: '550 user unknown'
    )

    expect(Campaigns::BounceHandler).to receive(:process).and_call_original
    expect(Campaigns::ReplyHandler).not_to receive(:process)

    result = described_class.new(email).process
    expect(result[:success]).to be(true)
    expect(result[:source]).to eq('campaign_bounce_handler')
    expect(result[:classification]).to eq(:bounce_hard)
  end

  it 'falls through to ReplyHandler when BounceHandler classifies as real_reply' do
    email = parsed(subject: 'Re: Welcome', body_text: 'Thanks for reaching out.')

    expect(Campaigns::BounceHandler).to receive(:process).and_call_original
    expect(Campaigns::ReplyHandler).to receive(:process).and_call_original

    result = described_class.new(email).process
    expect(result[:success]).to be(true)
    expect(result[:source]).to eq('campaign_reply_handler')
  end
end
