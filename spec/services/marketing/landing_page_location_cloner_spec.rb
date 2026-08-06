# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marketing::LandingPageLocationCloner do
  let(:company) { Company.create!(name: "Fan-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id)
  end
  let(:site) { Marketing::MarketingSiteProvisioner.call(company: company) }
  let(:form) { IntakeForm.create!(company_id: company.id, name: 'Enquiry', is_active: true) }

  let!(:denver)  { company.locations.create!(name: 'Denver Showroom') }
  let!(:boulder) { company.locations.create!(name: 'Boulder Showroom') }
  let!(:pueblo)  { company.locations.create!(name: 'Pueblo Showroom') }

  let(:page) do
    site.website_pages.create!(
      title: 'Spring Sale',
      path: '/spring-sale',
      page_kind: 'landing',
      intake_form_id: form.id,
      blocks: [
        { 'id' => 'b1', 'type' => 'hero', 'order' => 0,
          'content' => { 'title' => 'Spring Sale', 'subtitle' => 'Best pricing of the year' } },
        { 'id' => 'b2', 'type' => 'contact', 'order' => 1, 'content' => { 'intakeFormId' => form.id } },
        { 'id' => 'b3', 'type' => 'inventory', 'order' => 2, 'content' => { 'locationId' => denver.id } }
      ]
    )
  end

  def fan_out(locations = [denver, boulder, pueblo], **opts)
    described_class.new(page, user: user, locations: locations, **opts).call
  end

  it 'creates one page per location' do
    result = fan_out

    expect(result.cloned_count).to eq(3)
    expect(result.failed_count).to eq(0)
    expect(result.pages.map(&:title)).to contain_exactly(
      'Spring Sale — Denver Showroom',
      'Spring Sale — Boulder Showroom',
      'Spring Sale — Pueblo Showroom'
    )
  end

  # Named for the rooftop, not "(Copy)" — twelve pages all called
  # "(Copy) Spring Sale" are unusable in a list.
  it 'names each copy after its location' do
    expect(fan_out([boulder]).pages.first.title).to eq('Spring Sale — Boulder Showroom')
  end

  it 'gives every copy a distinct path' do
    paths = fan_out.pages.map(&:path)
    expect(paths.uniq.size).to eq(3)
  end

  # The decision: copy stays identical, only bound data varies.
  it 'keeps the marketing copy identical across locations' do
    heroes = fan_out.pages.map { |p| p.blocks.find { |b| b['type'] == 'hero' }['content'] }

    expect(heroes.map { |h| h['title'] }.uniq).to eq(['Spring Sale'])
    expect(heroes.map { |h| h['subtitle'] }.uniq).to eq(['Best pricing of the year'])
  end

  it 're-points each copy at its own location inventory' do
    result = fan_out
    by_title = result.pages.index_by(&:title)

    expect(by_title['Spring Sale — Boulder Showroom']
      .blocks.find { |b| b['type'] == 'inventory' }['content']['locationId']).to eq(boulder.id)
    expect(by_title['Spring Sale — Pueblo Showroom']
      .blocks.find { |b| b['type'] == 'inventory' }['content']['locationId']).to eq(pueblo.id)
  end

  it 'gives each copy its own form bound to its location' do
    result = fan_out
    form_ids = result.pages.map(&:intake_form_id)

    expect(form_ids.uniq.size).to eq(3)
    expect(form_ids).not_to include(form.id)
    expect(result.pages.map { |p| p.intake_form.location_id })
      .to contain_exactly(denver.id, boulder.id, pueblo.id)
  end

  it 'can share one pooled form instead' do
    result = fan_out(share_form: true)
    expect(result.pages.map(&:intake_form_id).uniq).to eq([form.id])
  end

  it 'leaves every copy unpublished' do
    expect(fan_out.pages.map(&:published?).uniq).to eq([false])
  end

  it 'defaults every copy to noindex' do
    expect(fan_out.pages.map(&:robots).uniq).to eq(['noindex, nofollow'])
  end

  # Deterministic: no AI call means no token spend and no credit limit,
  # regardless of how many rooftops.
  it 'makes no AI call' do
    expect(SiteProfiles::ProfileBuilder).not_to receive(:new)
    expect(AiQueryLog).not_to receive(:create!)
    fan_out
  end

  it 'carries the campaign link to every copy' do
    campaign = Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'C',
                                campaign_type: 'blast', from_identity_type: 'User',
                                from_identity_id: user.id, throttle_per_day: 100)
    page.update!(campaign_id: campaign.id)

    expect(fan_out.pages.map(&:campaign_id).uniq).to eq([campaign.id])
  end

  describe 'partial failure' do
    # One rooftop failing should not cost the others.
    it 'reports the failure and keeps the successes' do
      allow_any_instance_of(Marketing::LandingPageDuplicator).to receive(:call).and_wrap_original do |orig, *args|
        raise StandardError, 'boom' if orig.receiver.instance_variable_get(:@location) == boulder

        orig.call(*args)
      end

      result = fan_out

      expect(result.cloned_count).to eq(2)
      expect(result.failed_count).to eq(1)
      expect(result.failures.first[:location_name]).to eq('Boulder Showroom')
      expect(result.failures.first[:error]).to eq('boom')
    end
  end

  it 'handles an empty location list without raising' do
    result = fan_out([])
    expect(result.cloned_count).to eq(0)
    expect(result.failed_count).to eq(0)
  end
end
