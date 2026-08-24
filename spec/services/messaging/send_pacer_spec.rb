# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Messaging::SendPacer do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:user) { User.create!(email: "u-#{SecureRandom.hex(3)}@example.com", first_name: 'T', last_name: 'U', password: 'Pass1234!', company_id: company.id) }
  let(:connection) do
    UserEmailConnection.create!(user_id: user.id, company_id: company.id, provider: 'oauth_outlook',
                                email_address: "s-#{SecureRandom.hex(3)}@example.com", is_active: true)
  end
  let(:key) { "UserEmailConnection:#{connection.id}" }

  # oauth_outlook defaults: 10/min (6s) and 200/hour (18s). The wider rate wins.
  let(:limits) { Messaging::SendRateLimits.new(connection_key: key) }

  def queued_enrollment(at:)
    source = Source.find_or_create_by!(name: 'Web') { |s| s.source_type = 'web' }
    lead = Lead.create!(company: company, source: source, first_name: 'A', last_name: 'B',
                        email: "l-#{SecureRandom.hex(4)}@example.com")
    campaign = Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'C',
                                campaign_type: 'blast', from_identity_type: 'User',
                                from_identity_id: user.id, throttle_per_day: 500)
    CampaignEnrollment.create!(company_id: company.id, campaign_id: campaign.id,
                               recipient_type: 'Lead', recipient_id: lead.id,
                               email_address_snapshot: lead.email, status: 'pending',
                               sending_connection_key: key, next_send_at: at)
  end

  it 'spaces consecutive slots by the mailbox interval' do
    pacer = described_class.new(connection_key: key, earliest: Time.current, limits: limits)
    slots = Array.new(5) { pacer.next_slot }
    gaps = slots.each_cons(2).map { |a, b| (b - a).round }
    expect(gaps).to all(eq(18))
  end

  it 'ignores the daily quota when spacing, so a batch is not smeared over 24h' do
    # 2,000/day would imply 43s spacing if treated as a rate. It is a ceiling.
    expect(limits.interval_seconds).to eq(18.0)
  end

  it 'never schedules earlier than the requested earliest time' do
    earliest = 3.days.from_now
    pacer = described_class.new(connection_key: key, earliest: earliest, limits: limits)
    expect(pacer.next_slot).to be >= earliest
  end

  it 'does not pace when the mailbox is unknown' do
    pacer = described_class.new(connection_key: nil, earliest: Time.current)
    slots = Array.new(3) { pacer.next_slot }
    expect(slots.uniq.size).to eq(1)
  end

  # A second campaign enrolling into the same mailbox must queue behind the
  # first, not schedule on top of it.
  it 'starts far enough out to clear what the mailbox already has committed' do
    3.times { |i| queued_enrollment(at: (i + 1).minutes.from_now) }

    pacer = described_class.new(connection_key: key, earliest: Time.current, limits: limits)
    # Three committed sends at 18s each.
    expect(pacer.next_slot).to be_within(2.seconds).of(Time.current + 54.seconds)
  end

  # The regression that scheduled campaign 31's zero-wait first step four days
  # late. A mid-drip enrollment waiting out a five-day step is ONE message that
  # happens to be far away, not five days of queue depth.
  it 'does not queue behind a far-future drip wait' do
    queued_enrollment(at: 5.days.from_now)

    pacer = described_class.new(connection_key: key, earliest: Time.current, limits: limits)
    expect(pacer.next_slot).to be < 1.hour.from_now
  end

  it 'counts a send inside the horizon but not one beyond it' do
    queued_enrollment(at: 2.hours.from_now)
    queued_enrollment(at: 30.hours.from_now)

    pacer = described_class.new(connection_key: key, earliest: Time.current, limits: limits)
    # Only the 2-hour one is inside PACING_HORIZON, so one interval, not two.
    expect(pacer.next_slot).to be_within(2.seconds).of(Time.current + 18.seconds)
  end
end
