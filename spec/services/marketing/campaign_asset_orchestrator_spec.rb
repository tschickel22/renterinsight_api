# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marketing::CampaignAssetOrchestrator do
  let(:company) { Company.create!(name: "Orch-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id)
  end
  let(:brief) do
    Marketing::Brief.new(company: company, user: user, prompt: 'Spring sale, $0 down',
                         offer: '$0 down', tone: 'warm')
  end

  let(:plan) do
    { 'profile' => { 'copy' => { 'hero' => [{ 'headline' => 'Spring Sale' }] } },
      'form_fields' => [{ 'name' => 'email', 'type' => 'email' }],
      'layout_hint' => 'lp-offer-focus' }
  end

  before do
    allow_any_instance_of(LandingPages::AiBuilder).to receive(:call_claude).and_return(
      text: plan.to_json, model_version: 'claude-test', input_tokens: 10, output_tokens: 20
    )
  end

  it 'generates the landing page asset' do
    result = described_class.new(brief: brief).call

    expect(result.assets[:landing_page][:layout_hint]).to eq('lp-offer-focus')
    expect(result).not_to be_failed
  end

  # The whole point of Campaign Desk. Separate prompts produce a landing page
  # and an email that make different promises.
  it 'hands the generator the same brief it was given' do
    expect_any_instance_of(LandingPages::AiBuilder)
      .to receive(:generate).with(brief: brief).and_return({})

    described_class.new(brief: brief).call
  end

  # Campaign Desk lists landing pages as optional, so it must degrade rather
  # than error when a tenant does not have the module.
  it 'skips the landing page when it is not included' do
    expect_any_instance_of(LandingPages::AiBuilder).not_to receive(:generate)

    result = described_class.new(brief: brief, include_landing_page: false).call
    expect(result.assets).to be_empty
    expect(result).not_to be_failed
  end

  describe 'failures' do
    # A marketer who asked for three things and got two, clearly labelled, can
    # work with that. One who got an error page has nothing.
    it 'reports a generation failure without raising' do
      allow_any_instance_of(LandingPages::AiBuilder)
        .to receive(:generate).and_raise(StandardError, 'model timed out')

      result = described_class.new(brief: brief).call

      expect(result).to be_failed
      expect(result.failures[:landing_page][:error]).to eq('model timed out')
      expect(result.failures[:landing_page][:retryable]).to be(true)
    end

    # A credit limit is actionable and a retry will not help, so it is
    # distinguished from a transient failure.
    it 'marks a spent credit limit as not retryable' do
      allow_any_instance_of(LandingPages::AiBuilder)
        .to receive(:generate)
        .and_raise(LandingPages::AiBuilder::CreditLimitError, 'Monthly AI credit limit reached (50).')

      result = described_class.new(brief: brief).call

      expect(result.failures[:landing_page][:retryable]).to be(false)
      expect(result.failures[:landing_page][:error]).to match(/credit limit/i)
    end
  end

  describe 'campaign linkage' do
    let(:campaign) do
      Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'C',
                       campaign_type: 'blast', from_identity_type: 'User',
                       from_identity_id: user.id, throttle_per_day: 100)
    end
    let(:site) { Marketing::MarketingSiteProvisioner.call(company: company) }

    it 'exposes a campaign landing pages' do
      page = site.website_pages.create!(title: 'LP', path: '/lp', page_kind: 'landing',
                                        campaign_id: campaign.id)
      site.website_pages.create!(title: 'Other', path: '/other', page_kind: 'landing')

      expect(campaign.landing_pages).to contain_exactly(page)
    end

    it 'excludes ordinary site pages' do
      site.website_pages.create!(title: 'About', path: '/about', campaign_id: campaign.id)
      expect(campaign.landing_pages).to be_empty
    end

    # A landing page outlives the campaign that created it: still live, still
    # collecting leads.
    it 'survives the campaign being deleted' do
      page = site.website_pages.create!(title: 'LP', path: '/lp', page_kind: 'landing',
                                        campaign_id: campaign.id)
      page.publish!
      campaign.destroy

      page.reload
      expect(page).to be_persisted
      expect(page.campaign_id).to be_nil
      expect(page.published?).to be(true)
    end
  end
end
