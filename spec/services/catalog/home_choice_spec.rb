# frozen_string_literal: true

require 'rails_helper'
require_relative '../../support/fake_catalog_adapter'

# Which of a feed's homes a dealer carries, and moving a dealer between
# sources without re-creating homes (backlog E94).
RSpec.describe Catalog::HomeChoice do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:source) { create(:catalog_source, name: "Feed #{SecureRandom.hex(2)}", enabled: true) }
  let(:sub) { company.dealer_catalog_subscriptions.create!(catalog_source: source) }
  let(:homes) { %w[a b c].map { |k| FakeCatalogAdapter.home(k) } }

  def ingest(list = homes) = Catalog::SubscriptionIngestor.call(subscription: sub, homes: list)
  def live_keys = company.vehicles.where(catalog_source_id: source.id, is_deleted: [false, nil]).pluck(:catalog_source_key).sort

  it 'takes every home by default, as before' do
    ingest
    expect(live_keys).to eq(%w[a b c])
  end

  it 'removes a home left out at once, without waiting on the mass-removal hold, and restores it when ticked back' do
    ingest
    row = company.vehicles.find_by(catalog_source_key: 'b')
    sub.choose!(shown_keys: %w[a b c], kept_keys: %w[a])

    result = ingest
    expect(live_keys).to eq(%w[a])
    expect(result.held).to eq(0)
    expect(result.inactivated).to eq(2)

    sub.choose!(shown_keys: %w[a b c], kept_keys: %w[a b])
    ingest
    expect(live_keys).to eq(%w[a b])
    expect(company.vehicles.find_by(catalog_source_key: 'b', is_deleted: false).id).to eq(row.id)
  end

  it 'keeps a left-out home the dealer has worked on' do
    ingest
    company.vehicles.find_by(catalog_source_key: 'c').update_columns(status: 'available', sale_price: 99_000)
    sub.choose!(shown_keys: %w[a b c], kept_keys: %w[a b])

    ingest
    expect(live_keys).to eq(%w[a b c])
  end

  it 'holds a home new to the feed until the dealer decides' do
    sub.update!(new_homes: 'hold', reviewed_keys: %w[a b c])
    ingest(homes + [FakeCatalogAdapter.home('d')])
    expect(live_keys).to eq(%w[a b c])
    expect(sub.waiting?('d')).to be(true)

    sub.choose!(shown_keys: %w[d], kept_keys: %w[d])
    ingest(homes + [FakeCatalogAdapter.home('d')])
    expect(live_keys).to eq(%w[a b c d])
  end

  it 'still treats an empty crawl as a failed crawl when every home is left out' do
    ingest
    sub.choose!(shown_keys: %w[a b c], kept_keys: [])
    ingest
    expect(live_keys).to eq([])
    expect(ingest([]).inactivated).to eq(0)
  end

  it 'lists the feed with each home marked, and applies a choice straight away' do
    Catalog::ParsedHomeCache.write(source, homes)
    ingest

    list = described_class.homes(sub)
    expect(list[:from]).to eq('feed')
    expect(list[:homes].map { |h| [h[:key], h[:kept], h[:in_inventory]] }).to eq([['a', true, true], ['b', true, true], ['c', true, true]])

    result = described_class.apply!(sub, shown_keys: %w[a b c], kept_keys: %w[a c], new_homes: 'hold')
    expect(result).to include(applied: true, removed: 1)
    expect(live_keys).to eq(%w[a c])
    expect(sub.reload.new_homes).to eq('hold')
  end

  it 'marks the homes a price book of the dealer prices, by number and name' do
    mfr = Manufacturer.create!(name: "Cavco #{SecureRandom.hex(2)}", industry_type: 'manufactured_home')
    source.update!(manufacturer_id: mfr.id)
    factory = mfr.factories.create!(name: 'Plant City', code: "PC#{SecureRandom.hex(2)}", truebuild_released_at: Time.current)
    company.dealer_factories.create!(factory: factory)
    book = CatalogPriceBook.create!(manufacturer: mfr, factory: factory, name: 'Book', status: 'published', published_at: Time.current)
    plan = CatalogPlan.create!(manufacturer: mfr, factory: factory, series: 'Cavco Select', name: 'Cavco Select 15763A')
    variant = CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '15763A', building_code: 'HUD')
    CatalogVariantPrice.create!(price_book: book, variant: variant, net_base_price: 50_000)

    priced = described_class::PricedNumbers.new(company, source)
    expect(priced.include?('Cavco Select', '15763A', 'Cavco Select')).to be(true)
    expect(priced.include?('Tommie', '15763A', 'Elite')).to be(false)
    expect(priced.include?('Other', '28603A', 'Elite')).to be(false)
  end

  describe Catalog::SubscriptionMove do
    let(:plant) { create(:catalog_source, name: "Plant #{SecureRandom.hex(2)}", enabled: true) }

    it 'moves the same rows to the source that carries their keys, and drops the old subscription when none is left' do
      ingest
      ids = company.vehicles.where(catalog_source_id: source.id).pluck(:id).sort
      Catalog::ParsedHomeCache.write(plant, homes + [FakeCatalogAdapter.home('d')])

      report = described_class.call(company: company, from: source, to: [plant], new_homes: 'hold')

      expect(report).to include(moved: { plant.id => 3 }, left_behind: [], old_removed: true)
      expect(company.vehicles.where(catalog_source_id: plant.id).pluck(:id).sort).to eq(ids)
      expect(company.dealer_catalog_subscriptions.find_by(catalog_source_id: source.id)).to be_nil
      moved = company.dealer_catalog_subscriptions.find_by(catalog_source_id: plant.id)
      expect(moved.waiting?('d')).to be(true)
      expect(moved.wants?('a')).to be(true)
    end

    it 'leaves homes no target carries, and the old subscription with them' do
      ingest
      Catalog::ParsedHomeCache.write(plant, [FakeCatalogAdapter.home('a')])

      report = described_class.call(company: company, from: source, to: [plant])
      expect(report).to include(left_behind: %w[b c], old_removed: false)
      expect(company.dealer_catalog_subscriptions.find_by(catalog_source_id: source.id)).to be_present
    end

    it 'changes nothing on a dry run' do
      ingest
      Catalog::ParsedHomeCache.write(plant, homes)
      described_class.call(company: company, from: source, to: [plant], dry_run: true)
      expect(company.vehicles.where(catalog_source_id: source.id).count).to eq(3)
    end
  end
end
