# frozen_string_literal: true

require 'rails_helper'

RSpec.describe EmailCapService do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}", email_monthly_limit: 3) }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(3)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id)
  end
  let(:source) { Source.find_or_create_by!(name: 'Web') { |s| s.source_type = 'web' } }

  let(:campaign) do
    c = Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'E',
                         campaign_type: 'blast', channel: 'email', audience_mode: 'static',
                         from_identity_type: 'User', from_identity_id: user.id, throttle_per_day: 500)
    c.campaign_steps.create!(position: 0, channel: 'email', subject: 'Hi',
                             body_blocks: [{ 'type' => 'text', 'html' => 'a' }],
                             wait_days: 0, wait_hours: 0)
    c
  end

  # One enrollment per recipient per campaign is enforced, so each send needs its own lead.
  def enrollment(test_send: false)
    recipient = Lead.create!(company: company, source: source, first_name: 'A', last_name: '1',
                             email: "lead-#{SecureRandom.hex(4)}@x.com")
    CampaignEnrollment.create!(
      company_id: company.id, campaign_id: campaign.id, recipient_type: 'Lead',
      recipient_id: recipient.id, status: 'active', current_step_index: 0,
      email_address_snapshot: recipient.email, next_send_at: Time.current,
      metadata: test_send ? { 'test_send' => 'true' } : {}
    )
  end

  def record_sends(count, sent_at: Time.current, test_send: false)
    count.times do
      CampaignSend.create!(
        company_id: company.id, campaign_id: campaign.id,
        campaign_step_id: campaign.campaign_steps.first.id,
        campaign_enrollment_id: enrollment(test_send: test_send).id,
        sent_at: sent_at
      )
    end
  end

  describe 'under the cap' do
    it 'allows an automated send' do
      record_sends(2)

      expect(described_class.check!(company: company, source: 'campaign')).to eq(:ok)
    end
  end

  describe 'at the cap' do
    before { record_sends(3) }

    it 'blocks automated campaign sends' do
      expect { described_class.check!(company: company, source: 'campaign') }
        .to raise_error(described_class::CapExceededError, /3\/3/)
    end

    it 'warns but allows a manual send' do
      expect(described_class.check!(company: company, source: 'manual')).to eq(:over_cap)
    end
  end

  describe 'limit of zero' do
    it 'means unlimited' do
      company.update!(email_monthly_limit: 0)
      record_sends(50)

      expect(described_class.check!(company: company, source: 'campaign')).to eq(:unlimited)
    end
  end

  describe 'counting' do
    it 'ignores sends from a previous month' do
      record_sends(3, sent_at: 2.months.ago)

      expect(described_class.current_period_count(company)).to eq(0)
      expect(described_class.check!(company: company, source: 'campaign')).to eq(:ok)
    end

    it 'does not bill test sends' do
      record_sends(3, test_send: true)

      expect(described_class.current_period_count(company)).to eq(0)
    end

    it 'is scoped to the company' do
      other = Company.create!(name: "Other-#{SecureRandom.hex(3)}", email_monthly_limit: 3)
      record_sends(3)

      expect(described_class.current_period_count(other)).to eq(0)
    end
  end

  describe 'threshold notifications' do
    it 'fires an approaching-cap notification once as the line is crossed' do
      company.update!(email_monthly_limit: 10)
      record_sends(8)

      expect { described_class.check!(company: company, source: 'campaign') }
        .to have_enqueued_job(EmailCapNotificationJob).with(company.id, :approaching_cap)
    end

    it 'does not re-fire while sitting above the line' do
      company.update!(email_monthly_limit: 10)
      record_sends(9)

      expect { described_class.check!(company: company, source: 'campaign') }
        .not_to have_enqueued_job(EmailCapNotificationJob)
    end

    it 'fires an at-cap notification when the allowance runs out' do
      company.update!(email_monthly_limit: 10)
      record_sends(10)

      expect { described_class.check!(company: company, source: 'manual') }
        .to have_enqueued_job(EmailCapNotificationJob).with(company.id, :at_cap)
    end
  end
end
