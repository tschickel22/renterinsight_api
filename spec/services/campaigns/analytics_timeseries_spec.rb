# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Campaigns::AnalyticsTimeseries do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:user)    { User.create!(email: "u-#{SecureRandom.hex(3)}@example.com", first_name: 'T', last_name: 'U', password: 'Pass1234!', company_id: company.id) }
  let(:source)  { Source.find_or_create_by!(name: 'Web') { |s| s.source_type = 'web' } }
  let(:lead)    { Lead.create!(company: company, source: source, first_name: 'A', last_name: 'B', email: 'a@b.com') }

  let(:campaign) do
    c = Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'TS',
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
                               email_address_snapshot: lead.email, status: 'active')
  end

  def make_send(attrs = {})
    CampaignSend.create!(
      { company_id: company.id, campaign_id: campaign.id,
        campaign_step_id: step.id, campaign_enrollment_id: enrollment.id }.merge(attrs)
    )
  end

  describe '#buckets' do
    it 'returns all-zero buckets when the campaign has no sends' do
      ts = described_class.new(campaign: campaign, days: 5)
      result = ts.buckets
      expect(result.size).to eq(5)
      expect(result.map { |b| b[:sent] }).to all(eq(0))
      expect(result.map { |b| b[:opened] }).to all(eq(0))
      expect(result.map { |b| b[:bounced] }).to all(eq(0))
    end

    it 'returns one bucket per day for the requested window' do
      ts = described_class.new(campaign: campaign, days: 7)
      expect(ts.buckets.size).to eq(7)
      dates = ts.buckets.map { |b| b[:date] }
      expect(dates.last).to eq(Date.current.iso8601)
      expect(dates.first).to eq((Date.current - 6.days).iso8601)
    end

    it 'aligns sends to UTC dates so a 23:59 UTC send stays separate from 00:01 UTC the next day' do
      day_a = Date.current - 2.days
      day_b = Date.current - 1.day
      Time.use_zone('UTC') do
        make_send(sent_at: day_a.beginning_of_day + 23.hours + 59.minutes)
        make_send(sent_at: day_b.beginning_of_day + 1.minute)
      end

      buckets = described_class.new(campaign: campaign, days: 5).buckets.index_by { |b| b[:date] }
      expect(buckets[day_a.iso8601][:sent]).to eq(1)
      expect(buckets[day_b.iso8601][:sent]).to eq(1)
    end

    it 'counts sent from sent_at, opened from opened_at, bounced from bounced_at' do
      day_a = Date.current - 1.day
      day_b = Date.current
      make_send(sent_at: day_a.beginning_of_day + 9.hours, opened_at: day_b.beginning_of_day + 10.hours)
      make_send(sent_at: day_a.beginning_of_day + 10.hours, bounced_at: day_b.beginning_of_day + 11.hours, bounce_type: 'hard')

      buckets = described_class.new(campaign: campaign, days: 3).buckets.index_by { |b| b[:date] }
      expect(buckets[day_a.iso8601][:sent]).to eq(2)
      expect(buckets[day_a.iso8601][:opened]).to eq(0)
      expect(buckets[day_a.iso8601][:bounced]).to eq(0)
      expect(buckets[day_b.iso8601][:sent]).to eq(0)
      expect(buckets[day_b.iso8601][:opened]).to eq(1)
      expect(buckets[day_b.iso8601][:bounced]).to eq(1)
    end

    it 'counts clicked and replied independently from opened' do
      day = Date.current - 1.day
      make_send(sent_at: day.beginning_of_day + 1.hour,
                opened_at: day.beginning_of_day + 2.hours,
                clicked_at: day.beginning_of_day + 3.hours,
                replied_at: day.beginning_of_day + 4.hours)
      buckets = described_class.new(campaign: campaign, days: 3).buckets.index_by { |b| b[:date] }
      expect(buckets[day.iso8601][:clicked]).to eq(1)
      expect(buckets[day.iso8601][:replied]).to eq(1)
    end
  end

  describe 'days clamping' do
    it 'clamps zero/negative days down to 1' do
      ts = described_class.new(campaign: campaign, days: 0)
      expect(ts.buckets.size).to eq(1)
    end

    it 'clamps days above MAX_DAYS down to 365' do
      ts = described_class.new(campaign: campaign, days: 9999)
      expect(ts.buckets.size).to eq(described_class::MAX_DAYS)
    end
  end

  describe '#totals' do
    it 'sums each metric across all buckets' do
      day_a = Date.current - 1.day
      day_b = Date.current
      make_send(sent_at: day_a.beginning_of_day + 1.hour, opened_at: day_a.beginning_of_day + 2.hours)
      make_send(sent_at: day_b.beginning_of_day + 1.hour, opened_at: day_b.beginning_of_day + 2.hours)

      ts = described_class.new(campaign: campaign, days: 5)
      bucket_sum_sent = ts.buckets.sum { |b| b[:sent] }
      bucket_sum_opened = ts.buckets.sum { |b| b[:opened] }
      expect(ts.totals[:sent]).to eq(bucket_sum_sent)
      expect(ts.totals[:sent]).to eq(2)
      expect(ts.totals[:opened]).to eq(bucket_sum_opened)
      expect(ts.totals[:opened]).to eq(2)
    end
  end
end
