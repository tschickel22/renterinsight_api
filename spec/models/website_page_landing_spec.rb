# frozen_string_literal: true

require 'rails_helper'

RSpec.describe WebsitePage, type: :model do
  # Company creation seeds its own Corporate location, which is what the
  # provisioner resolves the container's location_id from.
  let(:company) { Company.create!(name: "LP-#{SecureRandom.hex(4)}") }
  let(:site) { Marketing::MarketingSiteProvisioner.call(company: company) }

  describe 'landing page defaults' do
    subject(:page) { site.website_pages.create!(title: 'Spring Sale', page_kind: 'landing') }

    # Clone-to-locations fans one offer across N rooftops with identical copy.
    # Indexing those would put a dozen near-identical pages in competition with
    # the dealer's actual site.
    it 'defaults to noindex' do
      expect(page.robots).to eq('noindex, nofollow')
    end

    it 'stays out of site nav and footer' do
      expect(page.show_in_nav).to be(false)
      expect(page.show_in_footer).to be(false)
    end

    it 'does not override an explicitly chosen robots value' do
      indexed = site.website_pages.create!(
        title: 'Indexed Offer', page_kind: 'landing', robots: 'index, follow'
      )
      expect(indexed.robots).to eq('index, follow')
    end

    # Defaults apply on create only, so an author who later switches a page to
    # index keeps that choice through subsequent saves.
    it 'does not re-apply the default on update' do
      page.update!(robots: 'index, follow', show_in_nav: true)
      page.reload
      expect(page.robots).to eq('index, follow')
      expect(page.show_in_nav).to be(true)
    end
  end

  describe 'ordinary pages' do
    subject(:page) { site.website_pages.create!(title: 'About Us') }

    it 'defaults to page_kind "page" and is untouched by landing defaults' do
      expect(page.page_kind).to eq('page')
      expect(page.landing_page?).to be(false)
      expect(page.robots).to be_nil
      expect(page.show_in_nav).to be(true)
    end
  end

  describe 'page-level publishing' do
    subject(:page) { site.website_pages.create!(title: 'Offer', page_kind: 'landing') }

    it 'starts unpublished even though the container site is published' do
      expect(site.status).to eq('published')
      expect(page.published?).to be(false)
    end

    it 'publishes and unpublishes at the page level' do
      page.publish!
      expect(page.published?).to be(true)
      expect(page.published_at).to be_present
      expect(described_class.published).to include(page)

      page.unpublish!
      expect(page.published?).to be(false)
      expect(page.published_at).to be_nil
      expect(described_class.published).not_to include(page)
    end
  end

  describe 'campaign linkage' do
    it 'is nullable — a standalone landing page has no campaign' do
      page = site.website_pages.create!(title: 'Standalone', page_kind: 'landing')
      expect(page.campaign).to be_nil
      expect(page).to be_valid
    end
  end

  describe 'validation' do
    it 'rejects an unknown page_kind' do
      page = site.website_pages.build(title: 'Bad', page_kind: 'brochure')
      expect(page).not_to be_valid
      expect(page.errors[:page_kind]).to be_present
    end
  end

  # These three columns were permitted by WebsitePagesController#page_params and
  # written by the frontend page clone, but did not exist. Rails raises on
  # unknown attributes rather than ignoring them, so per-page SEO was broken.
  describe 'previously missing SEO and hierarchy columns' do
    it 'persists robots and canonical_path' do
      page = site.website_pages.create!(
        title: 'SEO', robots: 'index, follow', canonical_path: '/canonical'
      )
      page.reload
      expect(page.robots).to eq('index, follow')
      expect(page.canonical_path).to eq('/canonical')
    end

    it 'supports parent/child pages' do
      parent = site.website_pages.create!(title: 'Parent')
      child = site.website_pages.create!(title: 'Child', parent_page_id: parent.id)

      expect(child.reload.parent_page).to eq(parent)
      expect(parent.child_pages).to include(child)
      expect(site.website_pages.top_level).to include(parent)
      expect(site.website_pages.top_level).not_to include(child)
    end
  end
end
