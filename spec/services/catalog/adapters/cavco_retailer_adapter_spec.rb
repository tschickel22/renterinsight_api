# frozen_string_literal: true

require 'rails_helper'

# Cavco's pages are a client-side SPA whose served HTML is an empty shell, so
# everything comes from their Elastic App Search engine. Documents are shaped
# { field => { "raw" => value } }, with photos/line_drawings arriving as
# JSON-encoded STRINGS inside the record.
RSpec.describe Catalog::Adapters::CavcoRetailerAdapter do
  let(:retailer_id) { 'd7db0a6e-5412-4b5d-8594-fd7cecb2ea4e' }
  let(:source) do
    build(:catalog_source, adapter_type: 'cavco_retailer',
                           base_url: 'https://www.cavcohomes.com/our-retailers/us/tx/amarillo/amarillo-home-center-llc',
                           config: { 'retailer_id' => retailer_id })
  end
  let(:adapter) { described_class.new(source) }

  # Mirrors a real floorplan document, including the quirks: nominal size in the
  # model number vs built size in the feet/inches fields, and media as strings.
  def floorplan(overrides = {})
    {
      'id' => 'c1f3a255-f2b1-4ffc-8895-adf0e26fe0a4',
      'name' => 'Jasper', 'model_number' => '28564A',
      'brand_name' => 'Halo', 'series' => 'Opal Ridge',
      'building_method' => 'Manufactured', 'sections' => 'Double-wide',
      'number_of_bedrooms' => 4.0, 'number_of_bathrooms' => 2.0, 'square_foot' => 1493.0,
      'width_feet' => '26', 'width_inches' => '8', 'length_feet' => '56', 'length_inches' => '0',
      'floorplan_availability' => ['Available to Purchase', 'In Stock Now'],
      'floorplan_retailers_in_stock' => [retailer_id],
      '3d_tour' => 'https://my.matterport.com/show/?m=qpiFR7QYzmQ',
      'video_tour' => 'https://www.youtube.com/watch?v=_O_qY-iwKgo',
      'photos' => [{ 'url' => 'https://cdn2.cavco.com/public/phhweb/a.jpg', 'alt' => 'exterior' }].to_json,
      'line_drawings' => [{ 'url' => 'https://cdn2.cavco.com/public/phhweb/plan.jpg' }].to_json,
      'plant_location_id' => ['639'],
      'url' => '/our-homes/solitairehomes/standard/us/639-opal-ridge-28564a',
      'type' => 'floorplan'
    }.merge(overrides)
  end

  def stub_documents(docs)
    client = instance_double(Catalog::CavcoSearchClient)
    allow(Catalog::CavcoSearchClient).to receive(:new).and_return(client)
    allow(client).to receive(:each_document) do |**_kw, &blk|
      docs.each { |d| blk.call(d) }
      docs.size
    end
    allow(client).to receive(:total_for).and_return(17)
    client
  end

  describe '#discover' do
    it 'returns every floorplan Cavco assigns this retailer' do
      stub_documents([floorplan, floorplan('id' => 'other', 'model_number' => '16602N')])
      expect(adapter.discover).to eq(['c1f3a255-f2b1-4ffc-8895-adf0e26fe0a4', 'other'])
    end

    it 'returns [] rather than raising when the engine is unreachable' do
      client = instance_double(Catalog::CavcoSearchClient)
      allow(Catalog::CavcoSearchClient).to receive(:new).and_return(client)
      allow(client).to receive(:each_document).and_raise(Catalog::CavcoSearchClient::Error, 'boom')

      expect(adapter.discover).to eq([])
    end

    it 'explains itself when no retailer is bound' do
      source.config = {}
      expect(adapter.discovery_hint).to match(/No retailer is bound/)
    end
  end

  describe '#parse' do
    subject(:home) { adapter.parse(adapter.fetch(adapter.discover.first)) }

    before { stub_documents([floorplan]) }

    it 'labels the model the way the site does' do
      expect(home.model_name).to eq('Jasper 28564A')
      expect(home.model_id).to eq('28564A')
    end

    it 'reads the series, which Cavco publishes directly' do
      expect(home.series).to eq('Opal Ridge')
    end

    # Jasper measures 26'8" x 56' but is merchandised as 28x56. Publishing the
    # built size would put a number on the listing no dealer recognises.
    it 'prefers the nominal size from the model number over the built size' do
      expect(home.dimensions).to eq('28x56')
    end

    # The bed digit is the free check on that reading.
    it 'falls back to the built size when the model number disagrees on beds' do
      stub_documents([floorplan('number_of_bedrooms' => 3.0)])
      expect(home.dimensions).to eq('27x56')
    end

    it 'falls back to the built size when the model number is not the usual shape' do
      stub_documents([floorplan('model_number' => 'CUSTOM-1')])
      expect(home.dimensions).to eq('27x56')
    end

    it 'maps section count and build method to property type' do
      expect(home.property_type).to eq(['Double Wide', 'Manufactured'])
    end

    it 'takes bed/bath/sqft from the record' do
      expect([home.bedrooms, home.bathrooms, home.square_feet]).to eq([4, 2, 1493])
    end

    # photos and line_drawings are JSON strings nested inside the document.
    it 'decodes photos and line drawings out of their JSON strings' do
      expect(home.image_source_urls).to contain_exactly(
        'https://cdn2.cavco.com/public/phhweb/a.jpg',
        'https://cdn2.cavco.com/public/phhweb/plan.jpg'
      )
    end

    it 'flags line drawings as floor plan art' do
      expect(home.floorplan_images.map { |i| i['source_url'] })
        .to eq(['https://cdn2.cavco.com/public/phhweb/plan.jpg'])
    end

    it 'captures the tour and the video separately' do
      expect(home.virtual_tour_url).to start_with('https://my.matterport.com/show/')
      expect(home.video_url).to include('youtube.com')
    end

    it 'ignores a tour URL from an unknown host' do
      stub_documents([floorplan('3d_tour' => 'https://example.com/not-a-tour')])
      expect(home.virtual_tour_url).to be_nil
    end

    it 'builds an absolute source URL' do
      expect(home.source_url).to start_with('https://www.cavcohomes.com/our-homes/')
    end

    # Cavco marks which retailers physically have the model on the lot.
    it 'marks stock when this retailer has it on the lot' do
      expect(home.raw['in_stock']).to be(true)
    end

    it 'does not claim stock from another retailer' do
      stub_documents([floorplan('floorplan_retailers_in_stock' => ['someone-else'])])
      fresh = described_class.new(source)
      expect(fresh.parse(fresh.fetch(fresh.discover.first)).raw['in_stock']).to be(false)
    end

    it 'carries the brand without filtering on it' do
      expect(home.raw['brand_name']).to eq('Halo')
    end

    # Cavco publishes no prose description on floorplans.
    it 'returns no description rather than inventing one' do
      expect(home.description).to be_nil
    end

    it 'passes the ingestion smoke test' do
      expect(home).to be_valid_smoke
    end
  end

  # One dealer carried 32563A four times under different brands. Keeping the
  # manufacturer's number is faithful; source_key is what must stay unique.
  describe 'a footprint sold under several brands' do
    before do
      stub_documents([
        floorplan('id' => 'a', 'name' => 'Cambridge', 'model_number' => '32563A', 'brand_name' => 'Ovation'),
        floorplan('id' => 'b', 'name' => 'Hidden Shores', 'model_number' => '32563A', 'brand_name' => 'Banner')
      ])
    end

    it 'keeps both, distinguished by name and source key' do
      homes = adapter.discover.map { |k| adapter.parse(adapter.fetch(k)) }
      expect(homes.map(&:model_id)).to eq(%w[32563A 32563A])
      expect(homes.map(&:source_key).uniq.size).to eq(2)
      expect(homes.map(&:model_name)).to contain_exactly('Cambridge 32563A', 'Hidden Shores 32563A')
    end
  end

  describe 'registry wiring' do
    it 'resolves from the adapter type' do
      expect(Catalog::AdapterRegistry.for(source)).to be_a(described_class)
      expect(CatalogSource::ADAPTER_TYPES).to include('cavco_retailer')
    end
  end
end
