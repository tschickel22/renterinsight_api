# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marketing::LandingPageDuplicator do
  let(:company) { Company.create!(name: "Dup-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id)
  end
  let(:site) { Marketing::MarketingSiteProvisioner.call(company: company) }
  let(:form) { IntakeForm.create!(company_id: company.id, name: 'Spring Sale Enquiry', is_active: true) }

  let(:page) do
    site.website_pages.create!(
      title: 'Spring Sale',
      path: '/spring-sale',
      page_kind: 'landing',
      layout_id: 'lp-offer-focus',
      intake_form_id: form.id,
      seo_title: 'Spring Sale',
      seo_description: 'Our best pricing of the year.',
      canonical_path: '/spring-sale',
      blocks: [
        { 'id' => 'block_a', 'type' => 'hero', 'order' => 0,
          'content' => { 'title' => 'Spring Sale', 'nested' => { 'deep' => 'value' } } },
        { 'id' => 'block_b', 'type' => 'contact', 'order' => 1,
          'content' => { 'title' => 'Enquire', 'intakeFormId' => form.id } },
        { 'id' => 'block_c', 'type' => 'inventory', 'order' => 2,
          'content' => { 'token' => 't', 'locationId' => 1 } }
      ]
    ).tap { |p| p.publish! }
  end

  def duplicate(**opts)
    described_class.new(page, user: user, **opts).call
  end

  describe 'what carries' do
    it 'copies blocks, style and SEO text' do
      copy = duplicate

      expect(copy.blocks.size).to eq(3)
      expect(copy.blocks.first['content']['title']).to eq('Spring Sale')
      expect(copy.seo_title).to eq('Spring Sale')
      expect(copy.seo_description).to eq('Our best pricing of the year.')
    end

    it 'deep-copies nested block content rather than sharing references' do
      copy = duplicate
      copy.blocks.first['content']['nested']['deep'] = 'changed'
      copy.save!

      expect(page.reload.blocks.first['content']['nested']['deep']).to eq('value')
    end

    it 'keeps the source profile and layout so the copy can be re-projected' do
      profile = SiteContentProfile.create!(company: company, source_url: 'https://example.com', status: 'ready')
      page.update!(site_content_profile_id: profile.id)

      copy = duplicate
      expect(copy.site_content_profile_id).to eq(profile.id)
      expect(copy.layout_id).to eq('lp-offer-focus')
    end
  end

  describe 'what resets' do
    # Inheriting canonical_path tells search engines the copy IS the original,
    # which is exactly backwards.
    it 'clears canonical_path' do
      expect(duplicate.canonical_path).to be_nil
    end

    it 'starts unpublished even when the original is live' do
      expect(page.published?).to be(true)

      copy = duplicate
      expect(copy.published?).to be(false)
      expect(copy.published_at).to be_nil
      expect(copy.is_visible).to be(false)
    end

    it 'gives every block a fresh id' do
      copy = duplicate
      original_ids = page.blocks.map { |b| b['id'] }

      expect(copy.blocks.map { |b| b['id'] }).not_to include(*original_ids)
      expect(copy.blocks.map { |b| b['id'] }.uniq.size).to eq(3)
    end

    it 'detaches from the campaign unless one is given' do
      page.update!(campaign_id: nil)
      expect(duplicate.campaign_id).to be_nil
    end

    it 'attaches to a campaign when asked' do
      campaign = Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'C',
                                  campaign_type: 'blast', from_identity_type: 'User',
                                  from_identity_id: user.id, throttle_per_day: 100)
      expect(duplicate(campaign_id: campaign.id).campaign_id).to eq(campaign.id)
    end

    it 're-applies the landing noindex default' do
      expect(duplicate.robots).to eq('noindex, nofollow')
    end

    it 'stays out of nav and footer' do
      copy = duplicate
      expect(copy.show_in_nav).to be(false)
      expect(copy.show_in_footer).to be(false)
    end
  end

  describe 'paths' do
    it 'gives the copy a unique path' do
      copy = duplicate
      expect(copy.path).to eq('/spring-sale-copy')
    end

    it 'does not collide when duplicated repeatedly' do
      paths = 3.times.map { duplicate.path }
      expect(paths.uniq.size).to eq(3)
    end

    # "spring-sale-copy-copy-copy" after three rounds is nobody's intent.
    it 'does not stack -copy suffixes when copying a copy' do
      first = duplicate
      second = described_class.new(first, user: user).call

      expect(second.path).to match(%r{\A/spring-sale-copy(-\d+)?\z})
    end
  end

  describe 'the intake form' do
    # Sharing one form across copies co-mingles submissions and makes per-page
    # attribution impossible, which is the whole point of the tracking.
    it 'clones the form by default' do
      copy = duplicate

      expect(copy.intake_form_id).to be_present
      expect(copy.intake_form_id).not_to eq(form.id)
      expect(copy.intake_form.name).to include('Spring Sale Enquiry')
    end

    it 'gives the cloned form its own public id and a zeroed submission count' do
      form.update!(submission_count: 42)
      clone = duplicate.intake_form

      expect(clone.public_id).to be_present
      expect(clone.public_id).not_to eq(form.public_id)
      expect(clone.submission_count).to eq(0)
    end

    it 'rebinds the contact block to the cloned form' do
      copy = duplicate
      contact = copy.blocks.find { |b| b['type'] == 'contact' }

      expect(contact['content']['intakeFormId']).to eq(copy.intake_form_id)
      expect(contact['content']['intakeFormId']).not_to eq(form.id)
    end

    it 'shares the original form when explicitly asked' do
      copy = duplicate(share_form: true)

      expect(copy.intake_form_id).to eq(form.id)
      expect(copy.blocks.find { |b| b['type'] == 'contact' }['content']['intakeFormId']).to eq(form.id)
    end

    it 'copes with a page that has no form' do
      page.update!(intake_form_id: nil)
      expect(duplicate.intake_form_id).to be_nil
    end
  end

  describe 'location re-pointing' do
    let(:branch) { company.locations.create!(name: 'Boulder Showroom') }

    it 'rebinds inventory blocks to the target location' do
      copy = duplicate(location: branch)
      inventory = copy.blocks.find { |b| b['type'] == 'inventory' }

      expect(inventory['content']['locationId']).to eq(branch.id)
    end

    it 'binds the cloned form to the target location' do
      expect(duplicate(location: branch).intake_form.location_id).to eq(branch.id)
    end

    it 'leaves inventory alone when no location is given' do
      inventory = duplicate.blocks.find { |b| b['type'] == 'inventory' }
      expect(inventory['content']['locationId']).to eq(1)
    end
  end

  describe 'guards' do
    it 'refuses to duplicate an ordinary site page this way' do
      ordinary = site.website_pages.create!(title: 'About', path: '/about')

      expect { described_class.new(ordinary, user: user).call }
        .to raise_error(described_class::DuplicationError, /Only landing pages/)
    end
  end
end
