# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Plays::PromoLandingPage do
  include ActiveJob::TestHelper

  let(:company) { Company.create!(name: "Summit Park #{SecureRandom.hex(3)}", industry: 'manufactured_housing') }
  let(:location) { company.inbound_lead_location }

  def make_user(role: 'sales_rep')
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'Rita', last_name: 'Rep',
                 password: 'Pass1234!', company_id: company.id, role: role, status: 'active')
  end

  let(:manager) { make_user(role: 'admin') }
  let(:rep) { make_user }
  let(:reps) { { location.id.to_s => [rep.id] } }

  before do
    ActiveJob::Base.queue_adapter = :test
    company.tenant_module_overrides.create!(module_key: 'marketing.landing_pages', is_enabled: true)
    allow(Plays::LeadResponsePlay).to receive(:texting_ready?).and_return(false)
    allow(CommunicationService).to receive(:send_email).and_return({ success: true })
  end

  let!(:facebook) { Plays::NewFacebookLead.new(company: company, user: manager, answers: { 'reps_by_location' => reps }).install! }

  def install(content = {})
    described_class.new(company: company, user: manager, answers: { 'content' => content }).install!
  end

  # The way the Customize panel saves: everything it was shown, with changes.
  def customize(installation, changes)
    current = described_class.installation_json(installation)[:content]
    described_class.new(company: company, user: manager, installation: installation,
                        answers: { 'content' => current.merge(changes) }).customize!
  end

  def sources_of(play, installation)
    play.answers_for(installation.reload)['sources']
  end

  describe '#install!' do
    it 'publishes a page with its form, files leads under its own source, and hands them to the chosen play' do
      installation = install('title' => 'Fall Sale', 'phone' => '(303) 555-1212', 'follow_up_play' => 'new_facebook_lead')
      page = described_class.page_for(installation)
      form = described_class.form_for(installation)

      expect(page).to have_attributes(path: '/fall-sale', page_kind: 'landing', intake_form_id: form.id, layout_id: 'lp-offer-focus')
      expect(page).to be_published
      expect(form).to have_attributes(location_id: location.id, is_active: true)
      expect(form.source.name).to eq('Promo landing page')
      expect(page.blocks.map { |b| b['type'] }).to eq(%w[hero features contact cta])
      expect(page.blocks[2]['content']['intakeFormId']).to eq(form.id)
      expect(page.blocks[3]['content']).to include('buttonLink' => 'tel:3035551212')

      expect(sources_of(Plays::NewFacebookLead, facebook)).to eq(['Facebook', 'Promo landing page'])
      json = described_class.installation_json(installation)
      expect(json[:follow_up_play]).to eq(key: 'new_facebook_lead', name: 'New Facebook lead')
      expect(json[:content]['follow_up_play']).to eq('new_facebook_lead')
      expect(json[:map].last[:title]).to eq('New Facebook lead follows up')
    end

    it 'refuses a follow-up play that is not on, and a plan without landing pages' do
      expect { install('follow_up_play' => 'walk_in_visit') }.to raise_error(Plays::InstallError, /follow-up play that is on/)

      company.tenant_module_overrides.find_by(module_key: 'marketing.landing_pages').update!(is_enabled: false)
      expect(described_class.definition(company)[:available]).to be false
      expect { install }.to raise_error(Plays::InstallError, /not part of your plan/)
    end
  end

  describe '#customize!' do
    it 'rewrites its words and keeps what was changed in the page editor' do
      installation = install('follow_up_play' => 'new_facebook_lead')
      page = described_class.page_for(installation)
      edited = page.blocks.map do |block|
        block['type'] == 'hero' ? block.deep_merge('content' => { 'backgroundImage' => 'https://example.com/mine.jpg' }) : block
      end
      page.update!(blocks: edited + [{ 'id' => 'block_gallery', 'type' => 'gallery', 'order' => 9, 'content' => { 'images' => [] } }])

      customize(installation, 'headline' => 'Last week of the sale', 'highlights' => [], 'publish' => false)

      page.reload
      expect(page.blocks.map { |b| b['type'] }).to eq(%w[hero contact gallery])
      expect(page.blocks.first['content']).to include('title' => 'Last week of the sale', 'backgroundImage' => 'https://example.com/mine.jpg')
      expect(page).not_to be_published
      expect(sources_of(Plays::NewFacebookLead, facebook)).to include('Promo landing page')

      customize(installation, 'highlights' => ['Zero down'], 'phone' => '303-555-0000')
      expect(page.reload.blocks.map { |b| b['type'] }).to eq(%w[hero features contact gallery cta])
    end

    it 'moves follow-up between plays and never leaves a play with nothing to start from' do
      installation = install('follow_up_play' => 'new_facebook_lead')
      walk_in = Plays::WalkInVisit.new(company: company, user: manager, answers: { 'reps_by_location' => reps }).install!

      customize(installation, 'follow_up_play' => 'walk_in_visit')
      expect(sources_of(Plays::NewFacebookLead, facebook)).to eq(['Facebook'])
      expect(sources_of(Plays::WalkInVisit, walk_in)).to include('Promo landing page')

      customize(installation, 'follow_up_play' => 'none')
      expect(sources_of(Plays::WalkInVisit, walk_in)).not_to include('Promo landing page')

      Plays::NewFacebookLead.new(company: company, user: manager, installation: facebook.reload,
                                 answers: Plays::NewFacebookLead.answers_for(facebook).merge('sources' => ['Promo landing page'])).customize!
      expect { customize(installation, 'follow_up_play' => 'none') }
        .to raise_error(Plays::InstallError, /starts only from Promo landing page/)
    end
  end

  describe '.uninstall!' do
    it 'takes the page down and stops the form' do
      installation = install
      described_class.uninstall!(installation)

      expect(described_class.page_for(installation)).not_to be_published
      expect(described_class.form_for(installation).is_active).to be false
    end
  end

  describe 'results' do
    let(:installation) { install('follow_up_play' => 'new_facebook_lead') }
    let(:form) { described_class.form_for(installation) }
    let(:page) { described_class.page_for(installation) }

    def submit(first_name)
      IntakeSubmission.create!(intake_form: form, status: 'new',
                               data: { 'first_name' => first_name, 'last_name' => 'May', 'email' => "#{first_name.downcase}@example.com" })
                      .reload.lead
    end

    def visit(token, converted:, lead: nil)
      PageVisit.create!(company_id: company.id, website_page: page, visitor_token: token, session_token: SecureRandom.hex(4),
                        first_seen_at: 1.hour.ago, last_seen_at: 50.minutes.ago, is_bot: false, converted: converted,
                        identified_entity: lead, utm_source: 'facebook', device_type: 'mobile')
    end

    it 'counts visits, leads and follow-up, lists each lead, and tells its journey' do
      tia = submit('Tia')
      DispatchWorkflowEventsJob.new.perform
      submit('Sam')
      ben = submit('Ben')
      ben.update_columns(is_converted: true, converted_at: Time.current)

      first = visit('v1', converted: true, lead: tia)
      visit('v1', converted: false)
      visit('v2', converted: false)
      PageVisitEvent.create!(page_visit: first, event_type: 'form_start', occurred_at: 1.hour.ago)

      expect(tia.source.name).to eq('Promo landing page')
      summary = described_class.performance_for(installation, period: '30', location_ids: nil)
      expect(summary[:stage_counts]).to eq('sent_form' => 1, 'in_follow_up' => 1, 'became_deal' => 1)
      expect(summary[:metrics]).to include(visits: 3, visitors: 2, form_starts: 1, leads: 3, conversion_rate: 0.5,
                                           followed_up: 1, deals: 1, published: true)

      list = described_class.leads_for(installation, period: '30', location_ids: nil, stage: 'in_follow_up', page: 1, per_page: 25)
      expect(list[:items].map { |i| i[:name] }).to eq(['Tia May'])
      expect(list[:items].first[:detail]).to eq('Followed up by New Facebook lead, started')
      expect(described_class.leads_for(installation, period: '30', location_ids: [0], stage: nil, page: 1, per_page: 25)[:meta][:total]).to eq(0)

      journey = described_class.lead_journey_for(installation, tia, location_ids: nil)
      expect(journey[:events].map { |e| e[:kind] }).to eq(%w[visit form assign])
      expect(journey[:events].first[:detail]).to eq('From facebook, mobile')
      expect(described_class.lead_journey_for(installation, Lead.create!(company_id: company.id, first_name: 'X', email: 'x@example.com'), location_ids: nil)).to be_nil
    end
  end
end
