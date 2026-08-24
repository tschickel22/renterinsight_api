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

  it 'enrolls only leads matching the filter_tree' do
    campaign.campaign_audience.update!(
      filter_tree: { 'type' => 'and', 'children' => [{ 'field' => 'first_name', 'operator' => 'equals', 'value' => 'A' }] }
    )
    described_class.new(campaign: campaign).enroll_all
    expect(campaign.campaign_enrollments.pluck(:recipient_id)).to contain_exactly(lead_a.id)
  end

  it 'does NOT enroll manually-excluded recipients (manual_exclude_ids)' do
    campaign.campaign_audience.update!(manual_exclude_ids: [lead_a.id])
    enrolled = described_class.new(campaign: campaign).enroll_all
    expect(enrolled).to eq(1)
    expect(campaign.campaign_enrollments.pluck(:recipient_id)).to contain_exactly(lead_b.id)
  end

  it 'applies exclude_filter_tree' do
    campaign.campaign_audience.update!(
      exclude_filter_tree: { 'type' => 'and', 'children' => [{ 'field' => 'first_name', 'operator' => 'equals', 'value' => 'B' }] }
    )
    described_class.new(campaign: campaign).enroll_all
    expect(campaign.campaign_enrollments.pluck(:recipient_id)).to contain_exactly(lead_a.id)
  end

  describe 'dynamic audience estimated_count stays live' do
    let(:dyn_campaign) do
      c = Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'D',
                           campaign_type: 'blast', channel: 'email', audience_mode: 'dynamic',
                           from_identity_type: 'User', from_identity_id: user.id, throttle_per_day: 100)
      c.campaign_steps.create!(position: 0, channel: 'email', subject: 'Hi',
                               body_blocks: [{ 'type' => 'text', 'html' => 'a' }], wait_days: 0, wait_hours: 0)
      c.create_campaign_audience!(source_type: 'Lead', filter_tree: {}, estimated_count: 0)
      c
    end

    it 'sets estimated_count to the live enrolled count after enrolling' do
      described_class.new(campaign: dyn_campaign).enroll_all
      expect(dyn_campaign.campaign_audience.reload.estimated_count).to eq(2)
    end

    it 'grows the count when a newly-matching lead is enrolled on a later run' do
      described_class.new(campaign: dyn_campaign).enroll_all
      expect(dyn_campaign.campaign_audience.reload.estimated_count).to eq(2)

      Lead.create!(company: company, source: source, first_name: 'C', last_name: '3', email: 'c@x.com')
      described_class.new(campaign: dyn_campaign).enroll_all
      expect(dyn_campaign.campaign_audience.reload.estimated_count).to eq(3)
    end

    it 'does not touch estimated_count for static campaigns' do
      campaign.campaign_audience.update!(estimated_count: 999)
      described_class.new(campaign: campaign).enroll_all
      expect(campaign.campaign_audience.reload.estimated_count).to eq(999)
    end
  end

  # Direct regression for the 2026-07-31 incident: enrolling 490 recipients gave
  # every one of them an identical next_send_at, so they all came due at once and
  # 225 went out in a single minute. Microsoft blocked the mailbox.
  describe 'send pacing' do
    let!(:connection) do
      UserEmailConnection.create!(user_id: user.id, company_id: company.id, provider: 'oauth_outlook',
                                  email_address: "s-#{SecureRandom.hex(3)}@example.com", is_active: true)
    end

    before do
      25.times do |i|
        Lead.create!(company: company, source: source, first_name: 'P', last_name: i.to_s,
                     email: "paced-#{i}@x.com")
      end
    end

    it 'spreads next_send_at across the audience instead of stacking it' do
      described_class.new(campaign: campaign).enroll_all
      times = campaign.campaign_enrollments.pluck(:next_send_at).compact.sort

      expect(times.size).to be >= 25
      expect(times.uniq.size).to eq(times.size)

      gaps = times.each_cons(2).map { |a, b| (b - a).round }
      expect(gaps).to all(eq(18))
    end

    it 'never schedules more than the per-minute limit into any one minute' do
      described_class.new(campaign: campaign).enroll_all
      per_minute = campaign.campaign_enrollments
                           .pluck(:next_send_at).compact
                           .group_by { |t| t.change(sec: 0) }
                           .transform_values(&:size)

      expect(per_minute.values.max).to be <= 10
    end

    it 'records which mailbox each enrollment will send through' do
      described_class.new(campaign: campaign).enroll_all
      keys = campaign.campaign_enrollments.pluck(:sending_connection_key).uniq
      expect(keys).to eq(["UserEmailConnection:#{connection.id}"])
    end
  end

  # Launch used to enqueue only this enroller, and nothing dispatched a send:
  # CampaignSchedulerJob's five-minute sweep was the sole path, so a first step
  # configured to wait zero days sat for up to five minutes while the builder
  # promised sending would begin immediately.
  describe 'dispatching an imminent first step' do
    it 'enqueues a send job for a zero-wait first step instead of waiting for the sweep' do
      expect { described_class.new(campaign: campaign).enroll_all }
        .to have_enqueued_job(ProcessCampaignSendJob).twice
    end

    # Dispatching early must not undo pacing. A paced slot is handed to the job
    # as wait_until, so the send still leaves at the instant it was allocated.
    it 'schedules a paced slot for its own time rather than firing the batch at once' do
      UserEmailConnection.create!(user_id: user.id, company_id: company.id, provider: 'oauth_outlook',
                                  email_address: "s-#{SecureRandom.hex(3)}@example.com", is_active: true)

      freeze_time do
        expect { described_class.new(campaign: campaign).enroll_all }
          .to have_enqueued_job(ProcessCampaignSendJob).at(18.seconds.from_now)
      end
    end

    it 'leaves a step whose wait puts it past the sweep to the scheduler' do
      campaign.campaign_steps.first.update!(wait_days: 3)

      expect { described_class.new(campaign: campaign).enroll_all }
        .not_to have_enqueued_job(ProcessCampaignSendJob)
    end
  end
end
