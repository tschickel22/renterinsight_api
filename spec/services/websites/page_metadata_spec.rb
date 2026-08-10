# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Websites::PageMetadata do
  let(:company) { Company.create!(name: 'Manufactured Home Elite') }
  let(:location) { company.locations.create!(name: 'Lot') }
  let(:website) do
    Website.create!(company_id: company.id, location_id: location.id, name: 'MHE',
                    slug: "s-#{SecureRandom.hex(4)}", status: 'published',
                    brand: { 'company_name' => 'Manufactured Home Elite Site 1' })
  end
  let(:page) { website.website_pages.create!(title: 'Inventory', path: '/inventory', order: 0, blocks: []) }

  def meta(page: nil, vehicle: nil)
    described_class.new(website: website, page: page, canonical_host: 'mhe.test', vehicle: vehicle).to_h
  end

  describe 'title length' do
    it 'appends the site name when the pair fits' do
      expect(meta(page: page)[:title]).to eq('Inventory | Manufactured Home Elite Site 1')
    end

    # Measured on a live site: every listing titled
    # "2026 Skyline Homes Prairie Dune 8710 | Manufactured Home Elite Site 1",
    # 69 characters, truncated mid model number in results.
    it 'drops the site name rather than let a home title be truncated' do
      home = company.vehicles.create!(vin: SecureRandom.hex(8), year: 2026, make: 'Skyline Homes',
                                      model: 'Prairie Dune 8710', status: 'available')

      title = meta(page: page, vehicle: home)[:title]

      expect(title).to eq('2026 Skyline Homes Prairie Dune 8710')
      expect(title.length).to be <= described_class::TITLE_LIMIT
    end
  end

  # A hero subtitle is written as a tagline, not as a search result, and it is
  # what an unfilled page falls back to. Measured live at 62 characters.
  describe 'short descriptions' do
    let(:tagline) do
      website.website_pages.create!(
        title: 'About Us', path: '/about', order: 4,
        blocks: [{ 'type' => 'hero', 'order' => 0, 'content' => {
          'title' => 'About Our Family',
          'subtitle' => 'Helping families achieve the dream of homeownership since 1998'
        } }]
      )
    end

    it 'names the dealership and where it is, both already on the record' do
      location.update!(address_line1: '123 Dealer Drive', city: 'Denver', state: 'CO')

      description = meta(page: tagline)[:description]

      expect(description).to eq(
        'Helping families achieve the dream of homeownership since 1998. ' \
        'Manufactured Home Elite Site 1, Denver, CO.'
      )
      expect(description.length).to be >= described_class::DESCRIPTION_MIN
    end

    it 'leaves a description that is already long enough alone' do
      page.update!(seo_description: 'A' * 120)

      expect(meta(page: page)[:description]).to eq('A' * 120)
    end

    it 'does not repeat the dealership when the copy already names it' do
      page.update!(seo_description: 'Come see Manufactured Home Elite Site 1.')

      expect(meta(page: page)[:description]).to eq('Come see Manufactured Home Elite Site 1.')
    end

    it 'stays silent when there is nothing to describe' do
      blank = website.website_pages.create!(title: 'Blank', path: '/blank', order: 5, blocks: [])

      expect(meta(page: blank)[:description]).to be_nil
    end
  end

  describe 'share previews' do
    let!(:home) do
      company.vehicles.create!(vin: SecureRandom.hex(8), year: 2026, make: 'Skyline Homes',
                               model: 'Prairie Dune', status: 'available',
                               images: [{ 'url' => 'https://cdn.test/front.jpg' }])
    end

    it 'previews a listing as the home itself' do
      expect(meta(page: page, vehicle: home)[:og_image]).to eq('https://cdn.test/front.jpg')
    end

    # A dealer who never uploaded a logo had no og:image on any brochure page, so
    # their links posted to Facebook and to a text message as bare grey boxes.
    it 'falls back to a home from the lot when the dealer has no logo' do
      expect(meta(page: page)[:og_image]).to eq('https://cdn.test/front.jpg')
    end

    it 'prefers the dealer\'s own logo when they have one' do
      website.update!(brand: website.brand.merge('logo_url' => 'https://cdn.test/logo.png'))

      expect(meta(page: page)[:og_image]).to eq('https://cdn.test/logo.png')
    end

    it 'never previews with a home the site would refuse to serve' do
      home.update!(status: 'sold')

      expect(meta(page: page)[:og_image]).to be_nil
    end
  end

  # The SEO tab and the site scanner both write default_title,
  # default_description and og_image_url. This class read title, description and
  # og_image, so everything a dealer typed and everything we scraped off their
  # old site was stored and then ignored.
  describe 'the SEO settings a dealer actually saves' do
    let(:blank_page) { website.website_pages.create!(title: 'X', path: '/x', order: 3, blocks: []) }

    it 'uses the title the SEO tab writes' do
      website.update!(seo_config: { 'default_title' => 'Manufactured Homes in Texas' })

      expect(meta(page: blank_page)[:title]).to include('Manufactured Homes in Texas')
    end

    it 'uses the description the SEO tab writes' do
      website.update!(seo_config: { 'default_description' => 'Shop new and used homes across Texas ' \
                                                             'with delivery and setup handled.' })

      expect(meta(page: blank_page)[:description]).to include('Shop new and used homes across Texas')
    end

    it 'uses the share image the scanner stores' do
      website.update!(seo_config: { 'og_image_url' => 'https://cdn.test/scanned.jpg' })

      expect(meta(page: blank_page)[:og_image]).to eq('https://cdn.test/scanned.jpg')
    end

    # Kept so anything written under the older spelling still resolves.
    it 'still honours the names this class used to read' do
      website.update!(seo_config: { 'title' => 'Older Spelling' })

      expect(meta(page: blank_page)[:title]).to include('Older Spelling')
    end

    # A page that says something specific beats the site-wide default.
    it 'lets a page override the site default' do
      website.update!(seo_config: { 'default_title' => 'Site Wide' })
      blank_page.update!(seo_title: 'This Page')

      expect(meta(page: blank_page)[:title]).to include('This Page')
    end
  end
end
