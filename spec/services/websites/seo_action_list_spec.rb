# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Websites::SeoActionList do
  let(:company) { Company.create!(name: 'List Homes', address_line1: '1 Lot', city: 'Denver', state: 'CO', zip_code: '80231') }
  let(:location) { company.locations.first || company.locations.create!(name: 'Lot') }
  let(:config) { {} }
  let(:website) do
    Website.create!(company_id: company.id, location_id: location.id, name: 'Site', slug: "s-#{SecureRandom.hex(4)}",
                    status: 'draft', tracking_config: config)
  end

  def keys(report = nil) = described_class.new(website: website, report: report).call.map { |i| i[:key] }

  describe 'analytics' do
    it 'asks for it when nothing is installed' do
      expect(keys).to include('analytics')
    end

    context 'with an id' do
      let(:config) { { 'google_analytics_id' => 'G-ABC12345' } }
      it { expect(keys).not_to include('analytics') }
    end

    context 'with Tag Manager' do
      let(:config) { { 'google_tag_manager_id' => 'GTM-ABC1234' } }
      it { expect(keys).not_to include('analytics') }
    end

    context 'pasted in by hand' do
      let(:config) { { 'custom_scripts' => { 'head' => "gtag('config','G-ABC12345')" } } }
      it { expect(keys).not_to include('analytics') }
    end
  end

  describe 'the Google Ads label' do
    it 'does not ask someone who does not advertise on Google' do
      expect(keys).not_to include('google_ads_conversion')
    end

    context 'with the tag on the site' do
      let(:config) { { 'google_ads_id' => 'AW-17782600637' } }

      it 'asks for the label, then stops, and the site reports leads to it' do
        expect(keys).to include('google_ads_conversion')

        company.save_tracking_defaults('googleAdsLeadLabel' => 'abcDEF123_x')
        fresh = Website.find(website.id)

        expect(described_class.new(website: fresh).call.map { |i| i[:key] }).not_to include('google_ads_conversion')
        expect(Websites::TrackingTags.new(website: fresh).call.head).to include('window.dtGoogleAdsLead = "AW-17782600637/abcDEF123_x"')
      end
    end

    it 'puts nothing on the site without a label' do
      website.update!(tracking_config: { 'google_ads_id' => 'AW-17782600637' })

      expect(Websites::TrackingTags.new(website: website).call.head).not_to include('dtGoogleAdsLead')
    end
  end

  describe 'home prices' do
    def home(attrs)
      company.vehicles.new({ status: 'available', is_deleted: false }.merge(attrs)).tap { |v| v.save!(validate: false) }
    end

    it 'counts homes the site shows with no price, and only those' do
      home(sale_price: nil)
      home(sale_price: 0)
      home(sale_price: 89_000)
      home(sale_price: nil, status: 'sold')

      item = described_class.new(website: website).call.find { |i| i[:key] == 'home_prices' }

      expect(item).to include(count: 2, title: 'Add prices to 2 homes', action: 'inventory')
    end

    it 'says nothing when every home has one' do
      home(sale_price: 89_000)

      expect(keys).not_to include('home_prices')
    end
  end

  describe 'page copy' do
    let(:report) do
      { 'checks' => [
        { 'key' => 'descriptions', 'status' => 'warn', 'urls' => ['https://x.example/about', 'https://x.example/homes/2026-home-1'] },
        { 'key' => 'titles', 'status' => 'pass', 'urls' => [] },
        { 'key' => 'headings', 'status' => 'warn', 'urls' => ['https://x.example/homes/2026-home-1'] },
        { 'key' => 'robots', 'status' => 'fail', 'urls' => ['https://x.example/robots.txt'] },
        { 'key' => 'rich_results', 'status' => 'warn', 'urls' => ['https://x.example/about'] },
        { 'key' => 'analytics_tracking', 'status' => 'fail', 'urls' => [] }
      ] }
    end

    it 'lists only what the dealer writes, on pages they edit, and no technical check' do
      items = described_class.new(website: website, report: report).call
      page_item = items.find { |i| i[:key] == 'descriptions' }

      expect(page_item).to include(count: 1, urls: ['https://x.example/about'], action: 'pages')
      expect(items.map { |i| i[:key] }).not_to include('titles', 'headings', 'robots', 'rich_results', 'analytics_tracking')
    end
  end

  it 'writes for a dealer: no dashes and no scan jargon' do
    website.update!(tracking_config: { 'google_ads_id' => 'AW-17782600637' })
    text = described_class.new(website: website).call.flat_map { |i| [i[:title], i[:detail]] }.join(' ')

    expect(text).not_to match(/[–—]|schema|crawler|structured data|canonical/i)
  end
end
