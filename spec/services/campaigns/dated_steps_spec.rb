# frozen_string_literal: true

require 'rails_helper'

# A step can send on a date and time instead of after a wait, for messages tied
# to a calendar day such as the day of an event.
RSpec.describe 'Dated campaign steps' do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:user)    { User.create!(email: "u-#{SecureRandom.hex(3)}@example.com", first_name: 'T', last_name: 'U', password: 'Pass1234!', company_id: company.id) }
  let(:source)  { Source.find_or_create_by!(name: 'Web') { |s| s.source_type = 'web' } }
  let(:denver)  { 'America/Denver' }
  let(:event)   { ActiveSupport::TimeZone[denver].local(2026, 10, 18, 9, 0) }

  let(:campaign) do
    c = Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'Open house',
                         campaign_type: 'drip', channel: 'email', audience_mode: 'static',
                         from_identity_type: 'User', from_identity_id: user.id, throttle_per_day: 100)
    c.campaign_steps.create!(position: 0, channel: 'email', subject: 'Invite',
                             body_blocks: [{ 'type' => 'text', 'html' => 'x' }])
    c.campaign_steps.create!(position: 1, channel: 'email', subject: 'Today', wait_days: 3,
                             body_blocks: [{ 'type' => 'text', 'html' => 'x' }],
                             send_at: event, send_at_timezone: denver)
    c.create_campaign_audience!(source_type: 'Lead', filter_tree: {})
    c
  end
  let(:dated) { campaign.campaign_steps.find_by(position: 1) }

  describe CampaignStep do
    it 'comes due at its date, ignoring the wait' do
      expect(dated.due_at(event - 10.days)).to eq(event)
    end

    it 'is still sendable later the same day in its own zone, and not the next day' do
      expect(dated.send_day_passed?(event + 14.hours)).to be false  # 11pm Denver
      expect(dated.send_day_passed?(event + 15.hours)).to be true   # just past midnight Denver
    end
  end

  describe CampaignEnrollment do
    it 'schedules the dated step for its date when the step before it sends' do
      l = Lead.create!(company: company, source: source, first_name: 'A', last_name: 'B', email: 'a@x.com')
      e = CampaignEnrollment.create!(company_id: company.id, campaign_id: campaign.id, recipient_type: 'Lead',
                                     recipient_id: l.id, email_address_snapshot: 'a@x.com', status: 'active',
                                     current_step_index: 0)
      travel_to(event - 5.days) { e.advance_to_next_step }
      expect(e.reload.next_send_at).to be_within(1.minute).of(event)
    end
  end

  describe Campaign do
    it 'blocks starting when a dated step has passed' do
      travel_to(event + 1.day) do
        expect(campaign.step_date_problems.first).to match(/Step 2 is set to send Sun, Oct 18, 2026 at 9:00 AM MDT, which has passed/)
        expect(campaign.can_start?).to be false
      end
    end

    it 'flags a dated step earlier than the dated step before it' do
      campaign.campaign_steps.create!(position: 2, channel: 'email', subject: 'Earlier',
                                      body_blocks: [{ 'type' => 'text', 'html' => 'x' }],
                                      send_at: event - 2.days, send_at_timezone: denver)
      travel_to(event - 10.days) do
        expect(campaign.step_date_problems).to eq(['Step 3 is dated before step 2, so it would be reached after its date.'])
      end
    end
  end

  describe Campaigns::CampaignSender do
    before { Setting.set('Company', company.id, 'require_marketing_consent', false) }

    it 'skips a dated step reached after its day is over' do
      l = Lead.create!(company: company, source: source, first_name: 'A', last_name: 'B', email: 'a@x.com')
      e = CampaignEnrollment.create!(company_id: company.id, campaign_id: campaign.id, recipient_type: 'Lead',
                                     recipient_id: l.id, email_address_snapshot: 'a@x.com', status: 'active',
                                     current_step_index: 1)
      sender = described_class.new(enrollment: e)
      travel_to(event + 1.day) { expect(sender.deliver_current_step).to be false }
      expect(sender.last_skip_reason).to eq('send_date_passed')
    end
  end

  describe Campaigns::AiBuilder do
    it 'reads a plan send_at as local time in the dealer zone and drops the wait' do
      plan = {
        'name' => 'Open house', 'channel' => 'email', 'campaign_type' => 'drip',
        'steps' => [
          { 'subject' => 'Invite', 'body_blocks' => [{ 'type' => 'text', 'html' => 'x' }] },
          { 'subject' => 'Today', 'wait_days' => 4, 'send_at' => '2026-10-18T09:00',
            'body_blocks' => [{ 'type' => 'text', 'html' => 'x' }] }
        ],
        'audience' => { 'source_type' => 'Lead', 'filter_tree' => {} }
      }
      gen = CampaignAiGeneration.create!(company: company, user: user, prompt: 'p', status: 'generated',
                                         generated_plan: plan, context_snapshot: { 'timezone' => denver })
      c = described_class.new(company: company, user: user).accept(
        generation: gen, sender_params: { from_identity_type: 'User', from_identity_id: user.id }
      )
      step = c.campaign_steps.find_by(position: 1)
      expect(step.send_at).to eq(event)
      expect(step.send_at_timezone).to eq(denver)
      expect(step.wait_days).to eq(0)
    end
  end
end
