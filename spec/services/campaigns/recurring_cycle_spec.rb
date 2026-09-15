# frozen_string_literal: true

require 'rails_helper'

# A recurring digest used to reach each person once, ever. These cover every
# piece that had to change for "weekly" to mean weekly.
RSpec.describe Campaigns::RecurringCycle do
  include ActiveJob::TestHelper

  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:user)    { User.create!(email: "u-#{SecureRandom.hex(3)}@example.com", first_name: 'T', last_name: 'U', password: 'Pass1234!', company_id: company.id) }
  let(:source)  { Source.find_or_create_by!(name: 'Web') { |s| s.source_type = 'web' } }
  let!(:lead)   { Lead.create!(company: company, source: source, first_name: 'Sam', last_name: 'K', email: 'sam@example.com') }

  let(:campaign) do
    c = Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'Weekly homes',
                         campaign_type: 'recurring_digest', channel: 'email', audience_mode: 'dynamic',
                         recurrence_cron: '0 9 * * 2', status: 'running',
                         from_identity_type: 'User', from_identity_id: user.id, throttle_per_day: 100)
    c.campaign_steps.create!(position: 0, channel: 'email', subject: 'Homes',
                              body_blocks: [{ 'type' => 'text', 'html' => 'a' }])
    c.create_campaign_audience!(source_type: 'Lead', filter_tree: {})
    c
  end

  before { ActiveJob::Base.queue_adapter = :test }

  def enroll(status: 'completed')
    CampaignEnrollment.create!(company_id: company.id, campaign_id: campaign.id,
                               recipient_type: 'Lead', recipient_id: lead.id,
                               email_address_snapshot: lead.email, status: status)
  end

  def test_enrollment(address)
    CampaignEnrollment.create!(company_id: company.id, campaign_id: campaign.id,
                               recipient_type: 'User', recipient_id: user.id,
                               email_address_snapshot: address, status: 'pending',
                               metadata: { 'test_send' => 'true' })
  end

  describe '#start!' do
    it "puts last cycle's recipients back on the first step" do
      enrollment = enroll
      enrollment.update!(current_step_index: 1)

      expect(described_class.new(campaign: campaign).start!).to eq(1)

      expect(enrollment.reload).to have_attributes(status: 'pending', current_step_index: 0)
      expect(enrollment.next_send_at).to be_present
      expect(campaign.reload.cycle_started_at).to be_present
    end

    it 'leaves unsubscribed recipients alone' do
      enrollment = enroll(status: 'unsubscribed')

      expect(described_class.new(campaign: campaign).start!).to eq(0)
      expect(enrollment.reload.status).to eq('unsubscribed')
    end

    it 'drops recipients who no longer match the audience' do
      enrollment = enroll
      campaign.campaign_audience.update!(
        filter_tree: { 'type' => 'and', 'children' => [{ 'field' => 'first_name', 'operator' => 'equals', 'value' => 'Nobody' }] }
      )

      expect(described_class.new(campaign: campaign).start!).to eq(0)
      expect(enrollment.reload.status).to eq('completed')
    end

    it 'does nothing for a campaign that is not recurring' do
      campaign.update!(campaign_type: 'blast', recurrence_cron: nil)
      enroll

      expect(described_class.new(campaign: campaign).start!).to eq(0)
    end
  end

  describe 'sending the same step in a new cycle' do
    let!(:connection) do
      UserEmailConnection.create!(user_id: user.id, provider: 'oauth_gmail', is_active: true,
                                  email_address: user.email, display_name: 'Test User')
    end

    before do
      allow(CommunicationService).to receive(:send_email).and_return(
        { success: true, communication: instance_double(Communication, id: 999, body: '<p>x</p>', update_column: true) }
      )
    end

    def enrollment_sent_last_week
      enrollment = enroll(status: 'pending')
      CampaignSend.create!(company_id: company.id, campaign_id: campaign.id,
                           campaign_step_id: campaign.campaign_steps.first.id,
                           campaign_enrollment_id: enrollment.id, sent_at: 7.days.ago)
      enrollment
    end

    it 'sends again once a new cycle has opened' do
      enrollment = enrollment_sent_last_week
      campaign.update_column(:cycle_started_at, 1.minute.ago)

      # reload: creating the enrollment cached the campaign from before the
      # cycle opened. The send job always loads the enrollment fresh.
      expect(Campaigns::CampaignSender.new(enrollment: enrollment.reload).deliver_current_step).to be true
      expect(enrollment.campaign_sends.where.not(sent_at: nil).count).to eq(2)
    end

    it 'still refuses a duplicate inside the same cycle' do
      enrollment = enrollment_sent_last_week
      campaign.update_column(:cycle_started_at, 8.days.ago)

      sender = Campaigns::CampaignSender.new(enrollment: enrollment.reload)
      sender.deliver_current_step

      expect(sender.last_skip_reason).to eq('already_sent_for_step')
    end
  end

  describe 'test sends' do
    it 'do not keep a recurring campaign from finishing its cycle' do
      enroll
      test_enrollment('admin@example.com')

      CampaignSchedulerJob.perform_now

      expect(campaign.reload.status).to eq('scheduled')
    end

    it 'do not shut out a real recipient who shares the address' do
      test_enrollment(lead.email)

      enrolled = Campaigns::AudienceEnroller.new(campaign: campaign).enroll_all

      expect(enrolled).to eq(1)
      expect(campaign.campaign_enrollments.real.pluck(:recipient_id)).to contain_exactly(lead.id)
    end
  end

  describe 'the scheduler opening a cycle' do
    it 'resets recipients when a scheduled recurring campaign comes due' do
      enrollment = enroll
      campaign.update!(status: 'scheduled', scheduled_at: 1.minute.ago)

      CampaignSchedulerJob.perform_now

      expect(campaign.reload.status).to eq('running')
      expect(enrollment.reload.status).to eq('pending')
    end
  end

  describe Campaigns::TemplateInstantiator do
    let(:template) do
      CampaignTemplate.create!(
        slug: "digest-#{SecureRandom.hex(3)}", name: 'Weekly Inventory Digest (recurring)',
        category: 'new_arrival_digest', vertical: 'manufactured_home', channel: 'email',
        audience_hint: { 'source_type' => 'Lead', 'filter_tree' => { 'type' => 'and', 'children' => [
          { 'field' => 'tags', 'operator' => 'tags_include', 'value' => 'weekly-digest-email' }
        ] } },
        send_window_template: { 'timezone' => 'America/Chicago', 'recurrence_cron' => '0 9 * * 2' },
        steps_template: [{ 'wait_days' => 0, 'subject' => 'Homes', 'body_blocks' => [] }]
      )
    end

    it 'starts a recurring template as a recurring campaign with a live audience' do
      created = described_class.new(template: template, company: company, user: user).call

      expect(created).to have_attributes(campaign_type: 'recurring_digest', audience_mode: 'dynamic',
                                         recurrence_cron: '0 9 * * 2')
      expect(created.send_window).to eq('timezone' => 'America/Chicago')
    end

    it 'creates the tag the audience filters on and points the filter at it' do
      created = described_class.new(template: template, company: company, user: user).call

      tag = company.tags.find_by(name: 'weekly-digest-email')
      expect(tag).to be_present
      expect(created.campaign_audience.filter_tree['children'].first['value']).to eq(tag.id)
      expect(template.reload.audience_hint['filter_tree']['children'].first['value']).to eq('weekly-digest-email')
    end

    it 'leaves a one-step template without a cadence as a blast' do
      template.update!(send_window_template: {})

      created = described_class.new(template: template, company: company, user: user).call

      expect(created).to have_attributes(campaign_type: 'blast', audience_mode: 'static', recurrence_cron: nil)
    end
  end
end
