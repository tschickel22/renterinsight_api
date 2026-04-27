# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Campaigns::BounceHandler do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:user)    { User.create!(email: "u-#{SecureRandom.hex(3)}@example.com", first_name: 'T', last_name: 'U', password: 'Pass1234!', company_id: company.id) }
  let(:source)  { Source.find_or_create_by!(name: 'Web') { |s| s.source_type = 'web' } }
  let(:lead)    { Lead.create!(company: company, source: source, first_name: 'A', last_name: 'B', email: 'recipient@example.com') }

  let(:campaign) do
    c = Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'B',
                         campaign_type: 'blast', from_identity_type: 'User', from_identity_id: user.id,
                         throttle_per_day: 100)
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

  def base_email(overrides = {})
    {
      from: 'someone@example.com',
      to: "reply+campaign-#{send_record.id}@mail.renterinsight.com",
      subject: 'Re: Welcome',
      body_text: 'Thanks for the email!',
      body_html: '<p>Thanks for the email!</p>',
      timestamp: Time.current,
      headers: '',
      content_type: 'text/plain'
    }.merge(overrides)
  end

  describe '.classify' do
    it 'returns :auto_reply when Auto-Submitted: auto-replied header is present' do
      email = base_email(headers: "Auto-Submitted: auto-replied\nFrom: bob@example.com\n", subject: 'Re: Welcome')
      expect(described_class.classify(email)).to eq(:auto_reply)
    end

    it 'returns :auto_reply when subject says "Out of Office"' do
      email = base_email(subject: 'Out of Office: Re: Welcome')
      expect(described_class.classify(email)).to eq(:auto_reply)
    end

    it 'returns :auto_reply when subject says "vacation"' do
      email = base_email(subject: 'On vacation until Monday')
      expect(described_class.classify(email)).to eq(:auto_reply)
    end

    it 'returns :bounce_hard on multipart/report DSN with 5.1.1 in body' do
      email = base_email(
        content_type: 'multipart/report; report-type=delivery-status; boundary="x"',
        subject: 'Delivery Status Notification (Failure)',
        body_text: 'The recipient address was rejected. Diagnostic-Code: smtp; 5.1.1 user unknown'
      )
      expect(described_class.classify(email)).to eq(:bounce_hard)
    end

    it 'returns :bounce_hard when from is mailer-daemon and body says user unknown' do
      email = base_email(
        from: 'MAILER-DAEMON@mail.example.com',
        subject: 'Returned mail: see transcript for details',
        body_text: '550 user unknown'
      )
      expect(described_class.classify(email)).to eq(:bounce_hard)
    end

    it 'returns :bounce_soft on bounce subject with quota exceeded body' do
      email = base_email(
        from: 'postmaster@example.com',
        subject: 'Undeliverable: Welcome',
        body_text: 'mailbox full — quota exceeded'
      )
      expect(described_class.classify(email)).to eq(:bounce_soft)
    end

    it 'defaults to :bounce_hard when DSN content-type is set but body does not match either pattern' do
      email = base_email(
        content_type: 'multipart/report; report-type=delivery-status',
        subject: 'Delivery Status Notification',
        body_text: 'opaque diagnostic'
      )
      expect(described_class.classify(email)).to eq(:bounce_hard)
    end

    it 'returns :real_reply for a normal reply with no auto-reply or bounce signals' do
      email = base_email(subject: 'Re: Welcome', body_text: "Thanks, looking forward to it!")
      expect(described_class.classify(email)).to eq(:real_reply)
    end
  end

  describe '.process' do
    it 'returns handled=false when send_id does not exist' do
      result = described_class.process(token: 'campaign-99999999', parsed_email: base_email)
      expect(result.handled).to be(false)
    end

    it 'returns handled=false when token does not start with campaign-' do
      result = described_class.process(token: 'lead-123', parsed_email: base_email)
      expect(result.handled).to be(false)
    end

    it 'on bounce_hard: creates suppression, marks send.bounce_type=hard, bounces enrollment, creates bounced_async event' do
      email = base_email(
        from: 'mailer-daemon@example.com',
        subject: 'Undeliverable: Welcome',
        body_text: '550 user unknown'
      )
      result = described_class.process(token: "campaign-#{send_record.id}", parsed_email: email)
      expect(result.handled).to be(true)
      expect(result.classification).to eq(:bounce_hard)

      send_record.reload
      expect(send_record.bounce_type).to eq('hard')
      expect(send_record.bounced_at).to be_present

      enrollment.reload
      expect(enrollment.status).to eq('bounced')
      expect(enrollment.bounced_at).to be_present

      expect(CampaignSuppression.where(company_id: company.id, email_address: 'recipient@example.com')).to exist
      expect(CampaignEvent.where(campaign_id: campaign.id, event_type: 'bounced_async')).to exist
    end

    it 'on bounce_soft: increments retry_count in metadata, no suppression created, creates bounced_async event' do
      email = base_email(
        from: 'postmaster@example.com',
        subject: 'Undeliverable: Welcome',
        body_text: 'mailbox full — quota exceeded'
      )
      result = described_class.process(token: "campaign-#{send_record.id}", parsed_email: email)
      expect(result.handled).to be(true)
      expect(result.classification).to eq(:bounce_soft)

      enrollment.reload
      expect(enrollment.metadata['retry_count']).to eq(1)
      expect(CampaignSuppression.where(email_address: 'recipient@example.com').count).to eq(0)
      expect(CampaignEvent.where(campaign_id: campaign.id, event_type: 'bounced_async').count).to eq(1)
    end

    it 'on auto_reply: creates auto_reply_received event only — no enrollment changes, no suppression' do
      email = base_email(subject: 'Out of Office: Re: Welcome')
      original_status = enrollment.status
      original_bounce_type = send_record.bounce_type

      result = described_class.process(token: "campaign-#{send_record.id}", parsed_email: email)
      expect(result.handled).to be(true)
      expect(result.classification).to eq(:auto_reply)

      enrollment.reload
      send_record.reload
      expect(enrollment.status).to eq(original_status)
      expect(send_record.bounce_type).to eq(original_bounce_type)
      expect(CampaignSuppression.where(company_id: company.id).count).to eq(0)
      expect(CampaignEvent.where(campaign_id: campaign.id, event_type: 'auto_reply_received').count).to eq(1)
    end

    it 'sets recipient.email_invalid=true on hard bounce when the model supports it' do
      # Lead has email_invalid in this codebase; if not, the spec still passes since it's optional behavior.
      skip 'Lead#email_invalid not present' unless Lead.column_names.include?('email_invalid')

      email = base_email(
        from: 'mailer-daemon@example.com',
        subject: 'Undeliverable: Welcome',
        body_text: '550 user unknown'
      )
      described_class.process(token: "campaign-#{send_record.id}", parsed_email: email)
      lead.reload
      expect(lead.email_invalid).to be(true)
    end
  end
end
