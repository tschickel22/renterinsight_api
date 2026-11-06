# frozen_string_literal: true

require 'rails_helper'

# One Cavco plant's whole line, whatever Cavco assigned to which dealer.
RSpec.describe Catalog::Adapters::CavcoPlantAdapter do
  let(:source) { build(:catalog_source, adapter_type: 'cavco_plant', config: { 'plant' => { 'id' => '34', 'name' => 'Plant City' } }) }
  let(:adapter) { described_class.new(source) }

  def floorplan(overrides = {})
    {
      'id' => 'a2685e29-d0a6-4cc5-a7f3-47e36eb3b8c1', 'name' => 'Ashley', 'model_number' => '28603A',
      'brand_name' => 'Palm Harbor', 'series' => 'Elite', 'sections' => 'Double-wide',
      'number_of_bedrooms' => 3.0, 'number_of_bathrooms' => 2.0, 'square_foot' => 1600.0,
      'photos' => [{ 'url' => 'https://cdn2.cavco.com/public/phhweb/a.jpg' }].to_json,
      'floorplan_retailers_in_stock' => ['some-dealer'], 'plant_location_id' => ['34'], 'type' => 'floorplan'
    }.merge(overrides)
  end

  it 'asks Cavco for the plant, as text' do
    client = instance_double(Catalog::CavcoSearchClient)
    allow(Catalog::CavcoSearchClient).to receive(:new).and_return(client)
    expect(client).to receive(:each_document)
      .with(filters: { 'all' => [{ 'type' => 'floorplan' }, { 'plant_location_id' => '34' }] }) { |**_kw, &blk| blk.call(floorplan) }

    expect(adapter.discover).to eq([floorplan['id']])
    home = adapter.parse(adapter.fetch(floorplan['id']))
    expect(home.model_name).to eq('Ashley 28603A')
    expect(home.dimensions).to eq('28x60')
    expect(home.images.size).to eq(1)
    expect(home.raw).to include('plant_id' => '34', 'in_stock' => false)
  end

  it 'has no dealer lot of its own' do
    expect(adapter.retailer_id).to be_nil
    expect(adapter.inventory_documents).to eq([])
    expect(adapter.include_inventory?).to be(false)
  end

  it 'says what is wrong when no plant is set' do
    bare = described_class.new(build(:catalog_source, adapter_type: 'cavco_plant', config: {}))
    expect(bare.discover).to eq([])
    expect(bare.discovery_hint).to include('No plant')
  end

  it 'is registered and named Cavco' do
    expect(Catalog::AdapterRegistry.for(source)).to be_a(described_class)
    expect(CatalogSource::ADAPTER_TYPES).to include('cavco_plant')
  end
end
