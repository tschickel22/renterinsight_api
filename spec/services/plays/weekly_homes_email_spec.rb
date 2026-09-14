# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Plays::WeeklyHomesEmail do
  include ActiveSupport::Testing::TimeHelpers

  let(:company) { Company.create!(name: "Summit Park #{SecureRandom.hex(3)}", industry: 'manufactured_housing') }
  let(:location) { company.locations.find_by(is_default: true) }
  let(:manager) do
    User.create!(email: "m-#{SecureRandom.hex(4)}@example.com", first_name: 'Mia', last_name: 'Manager',
                 password: 'Pass1234!', company_id: company.id, role: 'admin', status: 'active')
  end
  let(:rep) do
    User.create!(email: "r-#{SecureRandom.hex(4)}@example.com", first_name: 'Rita', last_name: 'Rep',
                 password: 'Pass1234!', company_id: company.id, role: 'sales_rep', status: 'active')
  end

  def install(content = {})
    described_class.new(company: company, user: manager, answers: { 'content' => content }).install!
  end

  def campaign_of(installation)
    described_class.campaign_for(installation)
  end

  describe '#install!' do
    it 'schedules a weekly campaign for tagged leads who have not become a deal' do
      installation = install('day' => 'thursday', 'time' => '08:30')
      campaign = campaign_of(installation)

      expect(campaign).to have_attributes(campaign_type: 'recurring_digest', audience_mode: 'dynamic', status: 'scheduled',
                                          recurrence_cron: '30 8 * * 4', from_identity_type: 'Owner')
      expect(campaign.scheduled_at).to eq(campaign.next_recurrence_at)
      expect(campaign.recurring?).to be true

      tag = company.tags.find_by(name: 'weekly-digest-email')
      children = campaign.campaign_audience.filter_tree['children']
      expect(children).to include({ 'field' => 'tags', 'operator' => 'tags_include', 'value' => tag.id },
                                  { 'field' => 'is_converted', 'operator' => 'equals', 'value' => false })
      expect(installation.asset_ids(:campaign_ids)).to eq([campaign.id])
    end

    it 'builds the email with the homes block and a working button' do
      campaign = campaign_of(install)
      step = campaign.campaign_steps.first

      expect(step.subject).to eq("{{first_name}}, this week's homes at #{company.name}")
      expect(step.body_blocks.map { |b| b['type'] }).to eq(%w[text inventory button footer_unsubscribe])
      expect(step.body_blocks[2]).to include('text' => 'See all our homes', 'href' => '{{public_inventory_url}}')
      expect(step.inventory_block_config).to include('mode' => 'segment_based', 'max_units' => 6, 'sort' => 'newest',
                                                     'fallback' => 'show_cta')
      expect(step.inventory_block_config.dig('filters', 'require_images')).to be true
    end

    it 'escapes the introduction and keeps merge fields' do
      campaign = campaign_of(install('intro' => "Hi {{first_name}} <b>\n\nSee {{dealership}}"))

      expect(campaign.campaign_steps.first.body_blocks.first['html'])
        .to eq("<p>Hi {{first_name}} &lt;b&gt;</p><p>See #{ERB::Util.html_escape(company.name)}</p>")
    end

    it 'refuses a second install, an unknown field, and a sender with no mailbox' do
      install
      expect { install }.to raise_error(Plays::InstallError, /already on/)

      PlayInstallation.update_all(status: 'uninstalled')
      expect { install('subject' => 'Hi {{rep_name}}') }.to raise_error(Plays::InstallError, /\{\{rep_name\}\} can't be used/)
      expect { install('sender' => 'company') }.to raise_error(Plays::InstallError, /Connect a dealership email/)
      expect { install('sender' => 'user', 'sender_user_id' => rep.id) }.to raise_error(Plays::InstallError, /connected email/)
    end
  end

  describe '#customize!' do
    it 'updates the campaign in place and moves the next send' do
      travel_to Time.zone.parse('2026-09-14 12:00 UTC') do
        installation = install
        campaign = campaign_of(installation)

        described_class.new(company: company, user: manager, installation: installation,
                            answers: { 'content' => { 'day' => 'friday', 'time' => '16:00', 'max_homes' => 3,
                                                      'subject' => 'New homes this week', 'match_budget' => false } }).customize!

        campaign.reload
        expect(campaign.recurrence_cron).to eq('0 16 * * 5')
        expect(campaign.scheduled_at).to eq(campaign.next_recurrence_at)
        expect(campaign.scheduled_at.in_time_zone(company.time_zone).wday).to eq(5)
        step = campaign.campaign_steps.first
        expect(step.subject).to eq('New homes this week')
        expect(step.inventory_block_config).to include('mode' => 'category_based', 'max_units' => 3)
        expect(Campaign.where(company_id: company.id).count).to eq(1)
        expect(installation.reload.answers.dig('content', 'day')).to eq('friday')
      end
    end
  end

  describe '.uninstall!' do
    it 'archives the campaign' do
      installation = install
      described_class.uninstall!(installation)

      expect(campaign_of(installation).status).to eq('archived')
      expect(installation.reload.status).to eq('uninstalled')
    end
  end

  describe 'results' do
    let(:installation) { install }
    let(:campaign) { campaign_of(installation) }
    let(:step) { campaign.campaign_steps.first }

    def lead(name, **attrs)
      Lead.create!(company_id: company.id, location_id: location.id, owner_id: rep.id, first_name: name, last_name: 'Buyer',
                   email: "#{name.downcase}-#{SecureRandom.hex(2)}@example.com", **attrs)
    end

    def enroll(lead, status: 'active', created_at: 3.days.ago)
      CampaignEnrollment.create!(company_id: company.id, campaign_id: campaign.id, recipient: lead, status: status,
                                 email_address_snapshot: lead.email, current_step_index: 0, created_at: created_at)
    end

    def send_to(enrollment, sent_at:, opened: false, clicked: false)
      CampaignSend.create!(company_id: company.id, campaign_id: campaign.id, campaign_step_id: step.id,
                           campaign_enrollment_id: enrollment.id, sent_at: sent_at,
                           opened_at: (sent_at + 1.hour if opened), clicked_at: (sent_at + 2.hours if clicked))
    end

    let!(:ana) { lead('Ana') }
    let!(:ben) { lead('Ben', is_converted: true, converted_at: 1.day.ago) }
    let!(:cy) { lead('Cy') }
    let!(:ana_enrollment) { enroll(ana) }
    let!(:ben_enrollment) { enroll(ben) }
    let!(:cy_enrollment) { enroll(cy, status: 'unsubscribed') }

    before do
      send_to(ana_enrollment, sent_at: 2.days.ago, opened: true, clicked: true)
      send_to(ben_enrollment, sent_at: 2.days.ago, opened: true)
      send_to(cy_enrollment, sent_at: 2.days.ago)
    end

    it 'counts who gets the email, how it is read, and what it led to' do
      summary = described_class.performance_for(installation, period: '30', location_ids: nil)

      expect(summary[:stages].map { |s| s[:key] }).to eq(%w[subscribed became_deal unsubscribed not_reachable])
      expect(summary[:stage_counts]).to eq('subscribed' => 1, 'became_deal' => 1, 'unsubscribed' => 1, 'not_reachable' => 0)
      expect(summary[:step_counts]).to eq('weekly_email' => 1)
      expect(summary[:metrics]).to include(recipients: 1, emails_sent: 3, open_rate: 0.667, click_rate: 0.333,
                                           leads_clicked: 1, unsubscribed: 1, deals: 1)
      expect(summary[:metrics][:next_send_at]).to eq(campaign.scheduled_at.iso8601)
    end

    it 'lists recipients by stage and hides other locations' do
      list = described_class.leads_for(installation, period: '30', location_ids: nil, stage: 'subscribed', page: 1, per_page: 25)
      expect(list[:items].map { |i| i[:name] }).to eq(['Ana Buyer'])
      expect(list[:items].first).to include(stage_label: 'Getting the weekly email', rep: 'Rita Rep',
                                            detail: 'Last email clicked, sent')

      hidden = described_class.leads_for(installation, period: '30', location_ids: [0], stage: nil, page: 1, per_page: 25)
      expect(hidden[:meta][:total]).to eq(0)
    end

    it "tells one lead's journey" do
      journey = described_class.lead_journey_for(installation, ana, location_ids: nil)

      expect(journey[:events].map { |e| e[:kind] }).to eq(%w[trigger email opened clicked])
      expect(journey[:lead]).to include(lead_id: ana.id, stage: 'subscribed')
      expect(described_class.lead_journey_for(installation, lead('Dee'), location_ids: nil)).to be_nil
    end
  end
end
