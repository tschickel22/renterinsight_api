# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Catalog::Adapters::ClaytonRetailHomeCenterAdapter do
  # Mirrors the real page shape: a Next.js App Router document whose data lives
  # in self.__next_f flight fragments (split mid-object, JS-escaped), with the
  # in-stock SKU list behind a "$W7c" lazy reference, plus the schema.org
  # HomeGoodsStore block that carries the parsed address.
  let(:slug)     { 'mobile-home-masters-inc' }
  let(:base_url) { "https://www.claytonhomes.com/locations/#{slug}" }

  let(:store_ld_json) do
    {
      '@context' => 'https://schema.org', '@type' => 'HomeGoodsStore',
      'name' => 'Mobile Home Masters Inc',
      'address' => { '@type' => 'PostalAddress', 'streetAddress' => '12010 State Hwy 31 E',
                     'addressLocality' => 'Tyler', 'addressRegion' => 'TX',
                     'postalCode' => '75705', 'addressCountry' => 'US' },
      'geo' => { '@type' => 'GeoCoordinates', 'latitude' => 32.3665, 'longitude' => -95.1299 },
      'telephone' => '9035967608', 'brand' => 'IND'
    }.to_json
  end

  let(:cards_payload) do
    {
      'cards' => [
        { 'type' => 'model', 'modelNumber' => '35MYO18803FH', 'modelName' => 'COLOSSAL',
          'beds' => 3, 'baths' => 2, 'squareFeet' => 1400, 'seriesName' => nil,
          'thumbnailImages' => [
            { 'src' => 'https://media.ffycdn.net/us/clayton-homes/aaa.jpg?cid=x', 'alt' => 'COLOSSAL - exterior' },
            { 'src' => 'https://media.ffycdn.net/us/clayton-homes/bbb.jpg?cid=x', 'alt' => 'COLOSSAL - floor plan' }
          ] },
        { 'type' => 'model', 'modelNumber' => '38SLT28563DH', 'modelName' => 'PT 78',
          'beds' => 3, 'baths' => 2, 'squareFeet' => 1474, 'seriesName' => nil,
          'thumbnailImages' => [{ 'src' => 'https://media.ffycdn.net/us/clayton-homes/ccc.jpg', 'alt' => 'PT 78' }] }
      ],
      'modelCount' => 2, 'moveInReadyCount' => 0, 'inStockIds' => '$W7c'
    }
  end

  let(:dealer_flight) do
    '["$","$L7a",null,{"dealerId":757055,"dealerNumber":"075705",' \
      '"dealerName":"Mobile Home Masters Inc","dealerPhone":"(903) 596-7608",' \
      '"dealerEmail":"jesse@mobilehomemasters.com",' \
      '"dealerAddress":"12010 State Hwy 31 E, Tyler, TX 75705","dealerBrand":"IND"}]'
  end

  # Escape exactly as the page does — JSON string escaping, minus the surrounding
  # quotes — so the fixture exercises the real unescaping path.
  def flight_script(raw)
    %(<script>self.__next_f.push([1,"#{raw.to_json[1..-2]}"])</script>)
  end

  let(:home_center_html) do
    cards_json = "79:#{cards_payload.to_json}"
    mid  = cards_json.length / 2
    head = cards_json[0...mid]
    tail = cards_json[mid..]
    <<~HTML
      <html><head>
        <script type="application/ld+json">#{store_ld_json}</script>
      </head><body>
        #{flight_script("74:#{dealer_flight}")}
        #{flight_script('7c:["35MYO18803FH"]')}
        #{flight_script(head)}#{flight_script(tail)}
      </body></html>
    HTML
  end

  let(:detail_html) do
    product = {
      '@context' => 'https://schema.org', '@type' => 'Product',
      'name' => 'The Colossal', 'mpn' => '35MYO18803FH',
      'image' => %w[
        https://api.claytonhomes.com/images/mfg/ext/one.jpg?cid=x
        https://api.claytonhomes.com/images/mfg/flp/plan.jpg
        https://cdn.example.com/not-clayton.jpg
        https://api.claytonhomes.com/images/mfg/logo.png
      ],
      'additionalProperty' => [
        { '@type' => 'PropertyValue', 'name' => 'Bedrooms', 'value' => 3 },
        { '@type' => 'PropertyValue', 'name' => 'Bathrooms', 'value' => 2 },
        { '@type' => 'PropertyValue', 'name' => 'Square feet', 'value' => 1400 }
      ]
    }.to_json
    %(<html><head><script type="application/ld+json">#{product}</script></head>
      <body><a href="https://my.matterport.com/show/?m=abc123">tour</a></body></html>)
  end

  let(:geo_html) do
    results = { 'total' => 2, 'results' => [
      { 'modelId' => 1, 'navigationSlug' => 'colossal', 'modelName' => 'Colossal', 'price' => 108_000 },
      { 'modelId' => 2, 'navigationSlug' => 'other',    'modelName' => 'Something Else', 'price' => 90_000 }
    ] }
    "<html><body>#{flight_script("48:#{results.to_json}")}</body></html>"
  end

  let(:source) do
    build(:catalog_source, adapter_type: 'clayton_retail_home_center',
                           base_url: base_url, config: { 'crawl_delay' => 0 })
  end
  let(:adapter) { described_class.new(source) }

  before do
    allow(adapter).to receive(:http_get) do |url, **|
      case url
      when base_url                                        then home_center_html
      when %r{/locations/#{slug}/homes/35MYO18803FH\z}      then detail_html
      when %r{/homes-for-sale/manufactured-homes/near/tyler-tx-75705\?page=1\z} then geo_html
      end
    end
  end

  describe '#discover' do
    it 'returns every orderable SKU from the flight payload, not just rendered cards' do
      expect(adapter.discover).to contain_exactly('35MYO18803FH', '38SLT28563DH')
    end

    it 'honours the limit' do
      expect(adapter.discover(limit: 1)).to eq(['35MYO18803FH'])
    end

    it 'returns [] rather than raising when the page is unavailable' do
      allow(adapter).to receive(:http_get).and_return(nil)
      expect(adapter.discover).to eq([])
    end
  end

  describe '#home_center' do
    subject(:hc) { adapter.home_center }

    it 'merges the flight dealer record with the LD+JSON address' do
      expect(hc).to include(
        'dealer_number' => '075705', 'dealer_id' => 757055, 'brand' => 'IND',
        'city' => 'Tyler', 'state' => 'TX', 'postal_code' => '75705',
        'latitude' => 32.3665, 'slug' => slug
      )
    end
  end

  describe '#parse' do
    subject(:home) { adapter.parse(adapter.fetch('35MYO18803FH')) }

    it 'prefers the detail page name and keeps the SKU as model_id' do
      expect(home.model_name).to eq('The Colossal')
      expect(home.model_id).to eq('35MYO18803FH')
    end

    it 'decodes dimensions and width class from the SKU tail' do
      expect(home.dimensions).to eq('18x80')
      expect(home.property_type).to eq(['Single Wide'])
    end

    it 'takes bed/bath/sqft from the listing card' do
      expect([home.bedrooms, home.bathrooms, home.square_feet]).to eq([3, 2, 1400])
    end

    it 'keeps only Clayton-hosted images, drops logos, and strips cache-busting queries' do
      expect(home.image_source_urls).to contain_exactly(
        'https://api.claytonhomes.com/images/mfg/ext/one.jpg',
        'https://api.claytonhomes.com/images/mfg/flp/plan.jpg'
      )
    end

    it 'flags floor plan art via the CDN path segment' do
      expect(home.floorplan_images.map { |i| i['source_url'] })
        .to eq(['https://api.claytonhomes.com/images/mfg/flp/plan.jpg'])
    end

    it 'captures the virtual tour' do
      expect(home.virtual_tour_url).to start_with('https://my.matterport.com/show/')
    end

    it 'joins the starting price from this market on a normalized model name' do
      expect(home.raw['starting_price']).to eq(108_000)
    end

    it 'marks in-stock SKUs resolved through the lazy flight reference' do
      expect(home.raw['in_stock']).to be(true)
    end

    it 'passes the ingestion smoke test' do
      expect(home).to be_valid_smoke
    end
  end

  describe 'models Clayton does not merchandise in this market' do
    subject(:home) { adapter.parse(adapter.fetch('38SLT28563DH')) }

    it 'still ingests, with no starting price and not in stock' do
      expect(home.model_name).to eq('PT 78')
      expect(home.raw['starting_price']).to be_nil
      expect(home.raw['in_stock']).to be(false)
      expect(home).to be_valid_smoke
    end

    it 'falls back to card thumbnails when the detail page is unavailable' do
      expect(home.image_source_urls).to eq(['https://media.ffycdn.net/us/clayton-homes/ccc.jpg'])
    end
  end

  describe 'starting price opt-out' do
    let(:source) do
      build(:catalog_source, adapter_type: 'clayton_retail_home_center', base_url: base_url,
                             config: { 'crawl_delay' => 0, 'include_starting_price' => false })
    end

    it 'skips the geo listing fetches entirely' do
      expect(adapter).not_to receive(:http_get).with(/homes-for-sale/, any_args)
      expect(adapter.parse(adapter.fetch('35MYO18803FH')).raw['starting_price']).to be_nil
    end
  end

  describe 'floorplan detection from card alt text' do
    let(:source) do
      build(:catalog_source, adapter_type: 'clayton_retail_home_center', base_url: base_url,
                             config: { 'crawl_delay' => 0, 'include_starting_price' => false })
    end

    it 'uses the alt suffix when only thumbnails are available' do
      allow(adapter).to receive(:http_get) do |url, **|
        url == base_url ? home_center_html : nil
      end
      home = adapter.parse(adapter.fetch('35MYO18803FH'))
      expect(home.floorplan_images.map { |i| i['source_url'] })
        .to eq(['https://media.ffycdn.net/us/clayton-homes/bbb.jpg'])
    end
  end

  describe 'registry wiring' do
    it 'resolves from the adapter type' do
      expect(Catalog::AdapterRegistry.for(source)).to be_a(described_class)
      expect(CatalogSource::ADAPTER_TYPES).to include('clayton_retail_home_center')
    end
  end
end
