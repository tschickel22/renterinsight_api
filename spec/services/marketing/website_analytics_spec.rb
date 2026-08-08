# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marketing::WebsiteAnalytics do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:location) { company.locations.create!(name: 'Lot') }
  let(:website) do
    Website.create!(company_id: company.id, location_id: location.id, name: 'Site',
                    slug: "s-#{SecureRandom.hex(4)}")
  end
  let(:page) { website.website_pages.create!(title: 'Inventory', path: '/inventory', order: 0) }

  def visit(source: nil, referrer: nil, converted: false, bot: false, token: SecureRandom.hex(4), at: 2.days.ago)
    PageVisit.create!(company_id: company.id, website_page_id: page.id,
                      visitor_token: token, session_token: SecureRandom.hex(4),
                      utm_source: source, referrer: referrer, converted: converted,
                      is_bot: bot, first_seen_at: at, last_seen_at: at)
  end

  def home(vehicle, event, on:)
    on.record_event!(event, { 'vehicle_id' => vehicle.id })
  end

  let(:shoal) do
    company.vehicles.create!(vin: SecureRandom.hex(8), year: 2026, make: 'Champion',
                             model: 'Shoal Creek', status: 'available', sale_price: 100_000)
  end
  let(:dune) do
    company.vehicles.create!(vin: SecureRandom.hex(8), year: 2026, make: 'Skyline',
                             model: 'Prairie Dune', status: 'available', sale_price: 90_000)
  end

  subject(:report) { described_class.new(website).call }

  describe 'traffic sources' do
    before do
      visit(source: 'facebook')
      visit(source: 'facebook')
      visit(source: 'google')
      visit(source: nil, referrer: 'https://www.facebook.com/some/post/123')
    end

    it 'counts visits by the source an ad platform set' do
      expect(report[:sources][:by_source]).to include('facebook' => 2, 'google' => 1)
    end

    # Most dealer links are never tagged, so untagged has to be a visible
    # bucket rather than silently dropped.
    it 'names untagged traffic instead of hiding it' do
      expect(report[:sources][:by_source]['untagged']).to eq(1)
    end

    # A dealer wants to know Facebook sent traffic, not which of 400 permalinks.
    it 'groups referrers by host' do
      expect(report[:sources][:by_referrer]).to include('facebook.com' => 1)
    end

    # The ranking worth acting on: a channel sending ten times the traffic at a
    # tenth of the conversion is a worse buy, and raw visits hide it.
    it 'reports which sources actually converted' do
      visit(source: 'google', converted: true)

      expect(described_class.new(website).call[:sources][:converting]).to eq('google' => 1)
    end
  end

  describe 'bots' do
    it 'excludes them, so paid comparisons are not inflated by crawlers' do
      visit(source: 'facebook')
      visit(source: 'facebook', bot: true)

      expect(report[:totals][:visits]).to eq(1)
      expect(report[:sources][:by_source]['facebook']).to eq(1)
    end
  end

  describe 'most interested homes' do
    before do
      v1 = visit
      v2 = visit
      home(shoal, 'home_detail', on: v1)
      home(shoal, 'home_detail', on: v2)
      home(shoal, 'home_view', on: v1)
      home(dune, 'home_detail', on: v1)
    end

    it 'ranks by opens, because opening a home is a decision' do
      expect(report[:homes].map { |h| h[:vehicle_id] }).to eq([shoal.id, dune.id])
      expect(report[:homes].first[:detail_views]).to eq(2)
    end

    it 'names the home so the row is readable without a lookup' do
      expect(report[:homes].first[:name]).to eq('2026 Champion Shoal Creek')
      expect(report[:homes].first[:price]).to eq(100_000)
    end

    it 'separates impressions from opens rather than collapsing them' do
      expect(report[:homes].first[:views]).to eq(1)
      expect(report[:homes].first[:detail_views]).to eq(2)
    end

    # Inquiries come off the lead record, not a beacon: a form submit that
    # reached the database is a fact, a beacon can be lost to a closed tab.
    it 'counts inquiries from leads that name the home' do
      company.leads.create!(first_name: 'A', last_name: 'B', vehicle_id: shoal.id)

      expect(described_class.new(website).call[:homes].first[:inquiries]).to eq(1)
    end

    it 'ignores events from another site\'s pages' do
      other = Website.create!(company_id: company.id, location_id: location.id, name: 'Other',
                              slug: "s-#{SecureRandom.hex(4)}")

      expect(described_class.new(other).call[:homes]).to be_empty
    end
  end

  describe 'the window' do
    it 'leaves out anything older than the window' do
      visit(at: 90.days.ago)

      expect(report[:totals][:visits]).to eq(0)
    end

    it 'honours an explicit range' do
      visit(at: 90.days.ago)

      widened = described_class.new(website, from: 120.days.ago, to: Time.current).call
      expect(widened[:totals][:visits]).to eq(1)
    end
  end

  describe 'the path to a sale' do
    # deal.stage is a configured key, not an enum, so a dealer who renamed their
    # pipeline must still be counted correctly.
    it 'counts sold against the tenant\'s own won stages' do
      contact = company.contacts.create!(first_name: 'A', last_name: 'B')
      # Real stages, validated by Company#valid_pipeline_stage?, so this cannot
      # pass against a key the tenant could not actually use.
      company.deals.create!(name: 'Won deal', contact: contact, stage: 'closed_won',
                            front_gross: 5_000)
      company.deals.create!(name: 'Open deal', contact: contact, stage: 'prospecting',
                            front_gross: 9_999)

      result = described_class.new(website).call
      expect(company.won_stage_keys).to eq(['closed_won'])
      expect(result[:totals][:sold]).to eq(1)
    end

    # front_gross is a METHOD computing margin from landed_cost, not the column
    # of the same name, and it returns nil when a deal has no cost basis. So the
    # column cannot be set to fake a gross, and this asserts the thing that is
    # actually ours: that gross is summed off the deal rather than recomputed,
    # and that only won deals contribute.
    it 'sums gross from the deal rather than recomputing it' do
      contact = company.contacts.create!(first_name: 'A', last_name: 'B')
      company.deals.create!(name: 'Won deal', contact: contact, stage: 'closed_won')
      company.deals.create!(name: 'Open deal', contact: contact, stage: 'prospecting')
      allow_any_instance_of(Deal).to receive(:front_gross).and_return(5_000)

      expect(described_class.new(website).call[:totals][:gross]).to eq(5_000.0)
    end

    it 'reports zero gross rather than failing when a deal has no cost basis' do
      contact = company.contacts.create!(first_name: 'A', last_name: 'B')
      company.deals.create!(name: 'Won deal', contact: contact, stage: 'closed_won')

      expect(described_class.new(website).call[:totals][:gross]).to eq(0.0)
    end
  end

  it 'returns an empty but well-formed report for a site with no traffic' do
    expect(report[:totals][:visits]).to eq(0)
    expect(report[:homes]).to eq([])
    expect(report[:sources][:by_source]).to eq({})
  end
end
