# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Plays::WakeUpColdLeads do
  include ActiveJob::TestHelper

  let(:company) { Company.create!(name: "Summit Park #{SecureRandom.hex(3)}", industry: 'manufactured_housing') }
  let(:location) { company.inbound_lead_location }
  let(:manager) do
    User.create!(email: "m-#{SecureRandom.hex(4)}@example.com", first_name: 'Mia', last_name: 'Manager',
                 password: 'Pass1234!', company_id: company.id, role: 'admin', status: 'active')
  end
  let(:rep) do
    User.create!(email: "r-#{SecureRandom.hex(4)}@example.com", first_name: 'Rita', last_name: 'Rep',
                 password: 'Pass1234!', company_id: company.id, role: 'sales_rep', status: 'active')
  end

  before { ActiveJob::Base.queue_adapter = :test }

  def install(content = {})
    described_class.new(company: company, user: manager, answers: { 'content' => content }).install!
  end

  def campaign_of(installation)
    described_class.campaign_for(installation)
  end

  def lead(name, idle_days: 100, **attrs)
    record = Lead.create!(company_id: company.id, location_id: location.id, owner_id: rep.id, first_name: name, last_name: 'Buyer',
                          email: "#{name.downcase}-#{SecureRandom.hex(2)}@example.com")
    record.update_columns({ last_activity_at: idle_days.days.ago }.merge(attrs))
    record
  end

  describe '#install!' do
    it 'starts a drip for quiet leads that stops on a reply or click, with rep task rules scoped to it' do
      installation = install('idle_days' => 90)
      campaign = campaign_of(installation)

      expect(campaign).to have_attributes(campaign_type: 'drip', audience_mode: 'dynamic', status: 'running', from_identity_type: 'Owner')
      expect(campaign.goal_config['goal_actions']).to eq('replied' => 'stop', 'clicked' => 'stop')
      steps = campaign.campaign_steps.order(:position)
      expect(steps.map { |s| [s.wait_days, s.subject] })
        .to eq([[0, 'Still looking, {{first_name}}?'], [7, 'A few homes worth a second look'], [7, 'Should we close your file?']])
      expect(steps.first.body_blocks.map { |b| b['type'] }).to eq(%w[text inventory footer_unsubscribe])
      expect(steps.last.body_blocks.map { |b| b['type'] }).to eq(%w[text footer_unsubscribe])

      audience = campaign.campaign_audience
      expect(audience).to have_attributes(exclude_active_campaign_enrollees: true, exclude_active_nurture_enrollees: true)
      expect(audience.filter_tree['children'])
        .to include({ 'field' => 'last_activity_at', 'operator' => 'days_since_greater_than', 'value' => 90 })

      rules = WorkflowRule.where(id: installation.asset_ids(:workflow_rule_ids))
      expect(rules.map { |r| r.trigger['event_type'] }).to contain_exactly('campaign.replied', 'campaign.clicked')
      expect(rules.map(&:status).uniq).to eq(['active'])
      expect(rules.map(&:conditions).uniq)
        .to eq([[{ 'field' => 'trigger.campaign_id', 'operator' => 'equals', 'value' => campaign.id }]])
      expect(CampaignAudienceEnrollerJob).to have_been_enqueued.with(campaign.id)
    end

    it 'enrolls quiet leads that have not become a deal and are not on the weekly homes email' do
      quiet = lead('Quiet')
      lead('Fresh', idle_days: 3)
      lead('Sold', is_converted: true)
      weekly = lead('Weekly')
      tag = company.tags.find_or_create_by!(name: 'weekly-digest-email') { |t| t.is_active = true }
      weekly.tag_assignments.create!(tag: tag, assigned_at: Time.current)

      campaign = campaign_of(install)
      Campaigns::AudienceEnroller.new(campaign: campaign).enroll_all

      expect(campaign.campaign_enrollments.pluck(:recipient_id)).to eq([quiet.id])
    end

    it 'refuses a sender with no mailbox, emails out of order, an unknown field, and no emails' do
      expect { install('sender' => 'company') }.to raise_error(Plays::InstallError, /Connect a dealership email/)

      emails = described_class.default_content['emails']
      expect { install('emails' => [emails[0], emails[1].merge('day' => 0)]) }.to raise_error(Plays::InstallError, /a day after/)
      expect { install('emails' => [emails[0].merge('subject' => 'Hi {{booking_link}}')]) }
        .to raise_error(Plays::InstallError, /\{\{booking_link\}\} can't be used/)
      expect { install('emails' => []) }.to raise_error(Plays::InstallError, /at least one/)
    end
  end

  describe '#customize!' do
    it 'updates the campaign in place, switches off dropped emails, and turns a task rule off' do
      installation = install
      campaign = campaign_of(installation)
      reply_rule = installation.assets['rules']['replied']
      click_rule = installation.assets['rules']['clicked']

      content = described_class.answers_for(installation)['content']
      content = content.merge('idle_days' => 30, 'skip_weekly' => false, 'click_task' => false,
                              'emails' => content['emails'].first(2))
      described_class.new(company: company, user: manager, installation: installation, answers: { 'content' => content }).customize!

      installation.reload
      expect(Campaign.where(company_id: company.id).count).to eq(1)
      expect(campaign.campaign_steps.order(:position).pluck(:is_active)).to eq([true, true, false])
      expect(campaign.campaign_audience.reload.exclude_filter_tree).to eq({})
      expect(campaign.campaign_audience.filter_tree['children'].first['value']).to eq(30)
      expect(installation.assets['rules']).to eq('replied' => reply_rule, 'clicked' => nil)
      expect(WorkflowRule.find(click_rule).status).to eq('archived')
    end
  end

  describe '.uninstall!' do
    it 'archives the campaign and its rules' do
      installation = install
      described_class.uninstall!(installation)

      expect(campaign_of(installation).status).to eq('archived')
      expect(WorkflowRule.where(id: installation.asset_ids(:workflow_rule_ids)).pluck(:status).uniq).to eq(['archived'])
    end
  end

  describe 'results' do
    let(:installation) { install }
    let(:campaign) { campaign_of(installation) }
    let(:steps) { campaign.campaign_steps.order(:position).to_a }

    def enroll(record, **attrs)
      CampaignEnrollment.create!({ company_id: company.id, campaign_id: campaign.id, recipient: record, status: 'active',
                                   email_address_snapshot: record.email, current_step_index: 0, created_at: 10.days.ago }.merge(attrs))
    end

    def sent(enrollment, step, **attrs)
      CampaignSend.create!({ company_id: company.id, campaign_id: campaign.id, campaign_step_id: step.id,
                             campaign_enrollment_id: enrollment.id, sent_at: 9.days.ago }.merge(attrs))
    end

    it 'counts who woke up, lists each lead by where it is, and tells its journey' do
      ana = lead('Ana')
      ben = lead('Ben')
      cy = lead('Cy')
      dee = lead('Dee')

      replied = enroll(ana, status: 'goal_met', goal_met_at: 8.days.ago, goal_met_reason: 'replied')
      sent(replied, steps[0], opened_at: 9.days.ago, replied_at: 8.days.ago)
      waiting = enroll(ben, current_step_index: 1, next_send_at: 2.days.from_now)
      sent(waiting, steps[0])
      finished = enroll(cy, status: 'completed')
      sent(finished, steps[0])
      enroll(dee)
      dee.update_columns(is_converted: true, converted_at: 1.day.ago)

      summary = described_class.performance_for(installation, period: '30', location_ids: nil)
      expect(summary[:stage_counts]).to include('woke_up' => 1, 'in_sequence' => 1, 'no_response' => 1, 'became_deal' => 1)
      expect(summary[:step_counts]).to eq('email_2' => 1)
      expect(summary[:metrics]).to include(leads_reached: 4, emails_sent: 3, woke_up: 1, woke_up_rate: 0.25, deals: 1)

      list = described_class.leads_for(installation, period: '30', location_ids: nil, stage: 'woke_up', page: 1, per_page: 25)
      expect(list[:items].map { |i| i[:name] }).to eq(['Ana Buyer'])
      expect(list[:items].first[:detail]).to eq('Responded (replied)')
      expect(described_class.leads_for(installation, period: '30', location_ids: [0], stage: nil, page: 1, per_page: 25)[:meta][:total]).to eq(0)

      journey = described_class.lead_journey_for(installation, ana, location_ids: nil)
      expect(journey[:events].map { |e| e[:kind] }).to eq(%w[trigger email opened reply])
    end
  end
end
