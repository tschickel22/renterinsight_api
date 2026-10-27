# frozen_string_literal: true

require 'rails_helper'

# Editing a step's timing moves the people still waiting on it (campaign 41:
# a first email changed from "wait 3 days" to "right away" still went out 3
# days later for everyone already enrolled).
RSpec.describe Campaigns::StepRescheduler do
  let(:company) { Company.create!(name: "C-#{SecureRandom.hex(4)}") }
  let(:user) { User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U', password: 'Pass1234!', company_id: company.id) }
  let(:source) { Source.find_or_create_by!(name: 'Web') { |s| s.source_type = 'web' } }
  let(:campaign) do
    Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'C', campaign_type: 'drip',
                     from_identity_type: 'User', from_identity_id: user.id, throttle_per_day: 100)
  end
  let!(:step0) { campaign.campaign_steps.create!(position: 0, is_active: true, wait_days: 3, wait_hours: 0, body_blocks: [{ 'type' => 'text', 'html' => '0' }]) }
  let!(:step1) { campaign.campaign_steps.create!(position: 1, is_active: true, wait_days: 5, wait_hours: 0, body_blocks: [{ 'type' => 'text', 'html' => '1' }]) }

  def enroll(step_index: 0, next_send_at:, status: 'pending', metadata: {}, last_sent_at: nil)
    lead = Lead.create!(company: company, source: source, first_name: 'B', last_name: SecureRandom.hex(2),
                        email: "b-#{SecureRandom.hex(4)}@example.com")
    CampaignEnrollment.create!(company_id: company.id, campaign_id: campaign.id, recipient_type: 'Lead',
                               recipient_id: lead.id, email_address_snapshot: lead.email, current_step_index: step_index,
                               status: status, next_send_at: next_send_at, metadata: metadata, last_sent_at: last_sent_at)
  end

  it 'brings sends forward to now when the wait is cut to nothing' do
    a = enroll(next_send_at: 3.days.from_now)
    b = enroll(next_send_at: 3.days.from_now + 18.seconds)
    freeze_time do
      step0.update!(wait_days: 0)
      expect(a.reload.next_send_at).to be <= Time.current + 1.second
      # Still 18 seconds behind the first, as the pacer spaced them.
      expect(b.reload.next_send_at).to be_within(1.second).of(Time.current + 18.seconds)
    end
  end

  it 'pushes sends out by the added wait, keeping their spacing' do
    t = 3.days.from_now.change(usec: 0)
    a = enroll(next_send_at: t)
    b = enroll(next_send_at: t + 18.seconds)
    step0.update!(wait_days: 4)
    expect(a.reload.next_send_at).to be_within(1.second).of(t + 1.day)
    expect(b.reload.next_send_at - a.next_send_at).to be_within(1.second).of(18.seconds)
  end

  it 'leaves people on other steps, finished people and test sends alone' do
    later = enroll(step_index: 1, status: 'active', next_send_at: 5.days.from_now, last_sent_at: Time.current)
    done = enroll(status: 'completed', next_send_at: 3.days.from_now)
    test = enroll(next_send_at: 3.days.from_now, metadata: { 'test_send' => 'true' })
    expect { step0.update!(wait_days: 0) }.not_to(change { [later, done, test].map { |e| e.reload.next_send_at.to_i } })
  end

  it 'does nothing when the edit does not touch timing' do
    a = enroll(next_send_at: 3.days.from_now)
    expect { step0.update!(subject: 'New subject') }.not_to(change { a.reload.next_send_at.to_i })
  end

  it 'times sends from a new date when the step becomes dated' do
    a = enroll(step_index: 1, status: 'active', next_send_at: 5.days.from_now, last_sent_at: 1.day.ago)
    date = 2.days.from_now.change(usec: 0)
    step1.update!(send_at: date)
    expect(a.reload.next_send_at).to be_within(1.second).of(date)
  end
end
