# frozen_string_literal: true

require 'rails_helper'

# A landlord's site shows vacancies from Renter Insight. The markup, the
# crawlable body and llms.txt must all say what the block says, and nothing
# when there is nothing open.
RSpec.describe Websites::RentalListings do
  let(:company) do
    Company.create!(name: 'The James Apts', industry: 'property_management', phone: '206-938-6228',
                    address_line1: '2124 California Ave SW', city: 'Seattle', state: 'WA')
  end
  let(:location) { company.locations.create!(name: 'The James') }
  let(:website) do
    Website.create!(company_id: company.id, location_id: location.id, name: 'The James', slug: "s-#{SecureRandom.hex(4)}",
                    brand: { 'company_name' => 'The James Apartments' },
                    seo_config: { 'businessType' => 'ApartmentComplex' })
  end
  let(:block) do
    { 'type' => 'rentalListings', 'order' => 1,
      'content' => { 'title' => 'Available Apartments', 'listingId' => '15914382',
                     'applyUrl' => 'https://app.renterinsight.com/apply/c-33755610', 'applyText' => 'Apply Now' } }
  end
  let!(:page) { website.website_pages.create!(title: 'Vacancies', path: '/vacancies', order: 1, blocks: [block]) }
  let(:studio) do
    { id: '54208600', title: 'Studio, Unit 203', unit: 'Unit 203', beds: 0, beds_label: 'Studio', baths: 1,
      sqft: 450, rent: 1400, deposit: 400, lease_term_months: 12, available_on: '2026-10-01',
      available_now: true, description: 'Hardwood floors and mahogany trim.', photo_url: 'https://cdn.test/a.jpg',
      listing_url: 'https://app.renterinsight.com/property-listings/15914382' }
  end
  let(:listings) { [studio] }

  before do
    allow(RenterInsight::PublicListings).to receive(:fetch).with('15914382')
      .and_return(listings: listings, property: nil)
  end

  def graph
    Websites::StructuredData.new(website: website, page: page, canonical_host: 'jamesapts.com').graph
  end

  describe 'structured data' do
    it 'marks the building as the type the site chose' do
      expect(graph.map { |n| n['@type'] }).to include('ApartmentComplex')
    end

    it 'ignores a business type outside the allowlist' do
      website.update!(seo_config: { 'businessType' => 'HomeGoodsStore' })
      expect(graph.map { |n| n['@type'] }).to include('RealEstateAgent')
    end

    it 'lists each open unit as an Apartment with a monthly rent offer' do
      list = graph.find { |n| n['@type'] == 'ItemList' && n['@id'].end_with?('#vacancies') }
      apt = list['itemListElement'].first['item']

      expect(apt).to include('@type' => 'Apartment', 'numberOfBedrooms' => 0, 'numberOfRooms' => 1,
                             'name' => 'Studio, Unit 203 at The James Apartments')
      expect(apt['floorSize']).to include('value' => 450, 'unitCode' => 'FTK')
      expect(apt['offers']).to include('price' => 1400, 'priceCurrency' => 'USD', 'availabilityStarts' => '2026-10-01')
      expect(apt['offers']['priceSpecification']).to include('unitCode' => 'MON')
      expect(apt['containedInPlace']).to eq('@id' => 'https://jamesapts.com/#store')
    end

    it 'gives the building a rent range when it has no homes for sale' do
      store = graph.find { |n| n['@type'] == 'ApartmentComplex' }
      expect(store['priceRange']).to eq('$1,400/month')
    end

    context 'with nothing open' do
      let(:listings) { [] }

      it 'emits no vacancy list' do
        expect(graph.none? { |n| n['@id'].to_s.end_with?('#vacancies') }).to be(true)
      end
    end
  end

  describe 'crawlable body' do
    def body
      Websites::BodyRenderer.new(website: website, page: page, canonical_host: 'jamesapts.com').call
    end

    it 'states each unit with rent, size, date and the apply link' do
      html = body

      expect(html).to include('<h1>Available Apartments</h1>', 'Studio, Unit 203',
                              'Studio, 1 bath, about 450 sq ft, $1,400/month, Available now',
                              'href="https://app.renterinsight.com/apply/c-33755610"')
    end

    context 'with nothing open' do
      let(:listings) { [] }

      it 'says so and offers no apply link' do
        expect(body).to include('join the waitlist')
        expect(body).not_to include('apply/c-33755610')
      end
    end
  end

  describe 'llms.txt' do
    it 'lists open units under their own heading' do
      txt = Websites::LlmsTxt.new(website: website, canonical_host: 'jamesapts.com').call

      expect(txt).to include('## Apartments available now',
                             '- [Studio, Unit 203](https://jamesapts.com/vacancies): Studio, about 450 sq ft, $1,400/month, Available now')
    end
  end
end
