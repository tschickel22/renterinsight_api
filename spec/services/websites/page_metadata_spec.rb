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
end
