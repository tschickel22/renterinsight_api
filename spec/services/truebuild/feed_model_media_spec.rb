# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Truebuild::FeedModelMedia do
  let(:mfr) { Manufacturer.create!(name: "Clayton #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:factory) { mfr.factories.create!(name: 'TRU', code: "TRU#{SecureRandom.hex(2)}") }
  let(:plan) { CatalogPlan.create!(manufacturer: mfr, factory: factory, series: 'TRU Origin', name: 'Dogwood') }
  let!(:dogwood) { CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '47TRT14602DH', width_ft: 14, length_ft: 60, building_code: 'HUD') }
  let!(:elm) { CatalogPlanVariant.create!(catalog_plan: CatalogPlan.create!(manufacturer: mfr, factory: factory, series: 'TRU Origin', name: 'Elm'), manufacturer: mfr, model_number: '47TRT14562EH', building_code: 'HUD') }
  let(:source) do
    CatalogSource.create!(name: "Clayton HC #{SecureRandom.hex(2)}", adapter_type: 'clayton_retail_home_center',
                          base_url: 'https://www.claytonhomes.com/locations/x', config: { 'factory_ids' => [factory.id] })
  end
  let(:home) do
    Catalog::NormalizedHome.new(source_key: '47TRT14602DH', model_name: 'DOGWOOD', images: [
      { 'source_url' => 'https://api.claytonhomes.com/ext/a.jpg', 'is_floorplan' => false },
      { 'source_url' => 'https://api.claytonhomes.com/int/b.jpg', 'is_floorplan' => false },
      { 'source_url' => 'https://api.claytonhomes.com/int/c.jpg', 'is_floorplan' => false },
      { 'source_url' => 'https://api.claytonhomes.com/fp/plan.jpg', 'is_floorplan' => true }
    ])
  end

  before do
    adapter = instance_double(Catalog::Adapters::ClaytonRetailHomeCenterAdapter, discover: ['47TRT14602DH'])
    allow(adapter).to receive(:fetch).and_return({})
    allow(adapter).to receive(:parse).and_return(home)
    allow(Catalog::AdapterRegistry).to receive(:for).with(source).and_return(adapter)
  end

  it 'links by the feed key, labels interior rooms once, and lists models the feed lacks' do
    calls = []
    tagger = lambda do |urls|
      calls << urls
      { 'https://api.claytonhomes.com/int/b.jpg' => 'kitchen', 'https://api.claytonhomes.com/int/c.jpg' => 'other' }
    end

    result = described_class.refresh!(source, tagger: tagger)

    rooms = dogwood.reload.media['photos'].to_h { |p| [p['url'].split('/').last, p['room']] }
    expect(rooms).to eq('a.jpg' => 'exterior', 'b.jpg' => 'kitchen', 'c.jpg' => 'other')
    expect(dogwood.media['floor_plans']).to eq(['https://api.claytonhomes.com/fp/plan.jpg'])
    expect(result).to include(linked: 1, unmatched: ['47TRT14562EH'], labelled: 2)

    described_class.refresh!(source, tagger: tagger)
    expect(calls.size).to eq(1)
  end

  it "links by the page's model number when the source keys on slugs" do
    home.source_key = 'the-dogwood'
    home.model_id = '47TRT14602DH'

    result = described_class.refresh!(source, tagger: ->(_urls) { {} })

    expect(dogwood.reload.media['photos'].size).to eq(3)
    expect(dogwood.external_ids['feed_key']).to eq('the-dogwood')
    expect(result).to include(linked: 1, unmatched: ['47TRT14562EH'])
  end

  it 'only reads sources that name the plants they feed' do
    source
    CatalogSource.create!(name: "Other #{SecureRandom.hex(2)}", adapter_type: 'clayton_retail_home_center', base_url: 'https://x', config: {})
    expect(described_class.sources).to eq([source])
  end
end
