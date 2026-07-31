# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Catalog::Adapters::TroveCatalogAdapter do
  let(:base_url) { 'https://trove.legacyhousing.com' }

  # Mirrors a real Trove product record: dimensions in inches, price in
  # hundredths ("micros"), full/half baths split, and images tagged by role.
  def home_record(overrides = {})
    {
      'short_id' => 'legacy-housing-heritage-collection-h-3260-32a',
      'name' => 'Heritage H-3260-32A',
      'internal_name' => 'Heritage H-3260-32A',
      'supplier_sku' => 'H-3260-32A',
      'supplier_id' => '675b01fe7fe1696cdf58f59a',
      'listed_status' => 'LISTED',
      'is_inventory' => false,
      'is_price_hidden' => false,
      'price' => { 'currency' => 'USD', 'cost_micros' => 8_149_500, 'retail_micros' => 10_890_000 },
      'details' => {
        'width_inches' => 384, 'length_inches' => 720, 'square_feet' => 1600,
        'bedrooms' => 3, 'bathrooms' => 2, 'half_bathrooms' => 0, 'sections' => 2,
        'covered_porch_sqft' => 0, 'kitchen_island_sqft' => 0,
        'descriptions' => [{ 'title' => nil, 'description' => '', 'category' => 'floor_plan' }],
        'embedded_media_urls' => ['https://my.matterport.com/show/?m=Q5hrJkhyjv4']
      },
      'images' => [
        { 'image_url' => 'https://trove.b-cdn.net/images/plan.png',
          'alt' => 'Heritage h-3260-32a floor plan home features', 'image_tags' => ['floor_plan'] },
        { 'image_url' => 'https://trove.b-cdn.net/images/hero.jpeg',
          'alt' => 'Heritage h-3260-32a hero, elevation, and exterior home features',
          'image_tags' => %w[hero elevation exterior] }
      ]
    }.deep_merge(overrides)
  end

  def snapshot_payload(homes)
    { 'schema' => Catalog::TroveSnapshot::SCHEMA, 'base_url' => base_url,
      'supplier_name' => 'Legacy Housing', 'captured_at' => '2026-07-30T23:24:03Z',
      'home_count' => homes.size, 'homes' => homes }
  end

  # ---------------------------------------------------------------- snapshot --
  describe 'snapshot-backed source' do
    let(:source) do
      build(:catalog_source, adapter_type: 'trove_catalog', base_url: base_url,
                             config: { 'snapshot_key' => 'legacy_housing' })
    end
    let(:adapter) { described_class.new(source) }

    before do
      allow(Catalog::TroveSnapshot).to receive(:read)
        .with('legacy_housing').and_return(snapshot_payload([home_record]))
    end

    it 'never touches the network' do
      expect(adapter).not_to receive(:http_get)
      adapter.discover
    end

    it 'discovers every home in the snapshot' do
      expect(adapter.discover).to eq(['legacy-housing-heritage-collection-h-3260-32a'])
    end

    it 'drops the crawl delay, since there is nothing to be polite to' do
      expect(adapter.crawl_delay).to eq(0)
    end

    it 'reports what it is running from, so a Test result is not mistaken for live' do
      expect(adapter.snapshot_info).to include(
        'key' => 'legacy_housing', 'supplier_name' => 'Legacy Housing', 'home_count' => 1
      )
    end

    describe 'the parsed home' do
      subject(:home) { adapter.parse(adapter.fetch(adapter.discover.first)) }

      it 'converts dimensions from inches to feet' do
        expect(home.dimensions).to eq('32x60')
      end

      it 'reads the series from the model name, which is where Trove puts it' do
        expect(home.series).to eq('Heritage')
      end

      it 'maps section count to width class' do
        expect(home.property_type).to eq(['Double Wide'])
      end

      it 'takes bed/bath/sqft from the details block' do
        expect([home.bedrooms, home.bathrooms, home.square_feet]).to eq([3, 2, 1600])
      end

      it 'flags floor plan art from the image tag' do
        expect(home.floorplan_images.map { |i| i['source_url'] })
          .to eq(['https://trove.b-cdn.net/images/plan.png'])
      end

      it 'captures the virtual tour' do
        expect(home.virtual_tour_url).to eq('https://my.matterport.com/show/?m=Q5hrJkhyjv4')
      end

      # Trove "micros" are hundredths: 10_890_000 is $108,900, not $10.89.
      it 'converts retail price out of micros into dollars' do
        expect(home.raw['retail_price']).to eq(108_900.0)
      end

      # MANAGED_FIELDS excludes price — retail is dealer-owned in DealerTide and
      # must never ride in on a sync.
      it 'keeps price off the home itself' do
        expect(home).not_to respond_to(:price)
        expect(home.raw).to include('retail_price')
      end

      # cost_micros is the manufacturer's invoice cost. It is in the page payload
      # but deliberately not ingested.
      it 'does not carry dealer cost anywhere' do
        expect(home.raw.to_json).not_to include('8149500')
        expect(home.raw.keys).not_to include('cost', 'cost_micros')
      end

      it 'passes the ingestion smoke test' do
        expect(home).to be_valid_smoke
      end
    end
  end

  # ------------------------------------------------------------ field quirks --
  describe 'real-world data quirks' do
    let(:source) do
      build(:catalog_source, adapter_type: 'trove_catalog', base_url: base_url,
                             config: { 'snapshot_key' => 'legacy_housing' })
    end
    let(:adapter) { described_class.new(source) }

    def parse_first(record)
      allow(Catalog::TroveSnapshot).to receive(:read).and_return(snapshot_payload([record]))
      adapter.parse(adapter.fetch(adapter.discover.first))
    end

    # Legacy writes some SKUs with a multiplication sign.
    it 'normalizes the typographic multiplication sign in a SKU' do
      home = parse_first(home_record('supplier_sku' => 'H-32×72-43A'))
      expect(home.model_id).to eq('H-32x72-43A')
    end

    # 7 of Legacy's 93 records ship no supplier_sku at all.
    it 'falls back to the model name minus its series word when the SKU is missing' do
      home = parse_first(home_record('supplier_sku' => nil, 'name' => 'Workforce O-18×80-44A'))
      expect(home.model_id).to eq('O-18x80-44A')
    end

    it 'combines full and half baths into one decimal' do
      home = parse_first(home_record('details' => { 'bathrooms' => 2, 'half_bathrooms' => 1 }))
      expect(home.bathrooms).to eq(2.5)
    end

    it 'leaves whole bath counts as integers' do
      expect(parse_first(home_record).bathrooms).to eq(2)
    end

    # Legacy publishes the description scaffold with empty bodies on every record.
    it 'returns no description rather than inventing one' do
      expect(parse_first(home_record).description).to be_nil
    end

    it 'keeps a description when one is actually published' do
      record = home_record
      record['details']['descriptions'] = [{ 'description' => 'A roomy three bedroom.' }]
      expect(parse_first(record).description).to eq('A roomy three bedroom.')
    end

    it 'ignores non-Trove image hosts' do
      record = home_record
      record['images'] << { 'image_url' => 'https://cdn.example.com/other.jpg', 'image_tags' => [] }
      expect(parse_first(record).image_source_urls).to all(include('trove.b-cdn.net'))
    end

    it 'marks in-stock inventory units' do
      expect(parse_first(home_record('is_inventory' => true)).raw['in_stock']).to be(true)
    end

    # Legacy still ships a price on call-for-quote models, but it is a
    # placeholder — $900 on all 7 of its Workforce units. Publishing that would
    # put a $900 home in front of a buyer.
    it 'suppresses the placeholder price on call-for-quote models' do
      home = parse_first(home_record('is_price_hidden' => true,
                                     'price' => { 'retail_micros' => 90_000 }))
      expect(home.raw['retail_price']).to be_nil
      expect(home.raw['price_hidden']).to be(true)
    end
  end

  # -------------------------------------------------------------------- live --
  describe 'live crawl' do
    let(:source) do
      build(:catalog_source, adapter_type: 'trove_catalog', base_url: base_url,
                             config: { 'crawl_delay' => 0 })
    end
    let(:adapter) { described_class.new(source) }

    # Escape exactly as Next.js does — JSON string escaping minus the quotes —
    # so the fixture exercises the real unescaping path.
    def flight_script(raw)
      %(<script>self.__next_f.push([1,"#{raw.to_json[1..-2]}"])</script>)
    end

    let(:index_html) do
      payload = "12:#{{ 'homes' => [home_record] }.to_json}"
      mid  = payload.length / 2
      "<html><body>#{flight_script(payload[0...mid])}#{flight_script(payload[mid..])}</body></html>"
    end

    # A detail page also renders cards for OTHER models, so its payload carries
    # their images. Only alt text distinguishes them.
    let(:detail_html) do
      payload = '8:' + {
        'images' => [
          # model-specific alt — unambiguously ours
          { 'image_url' => 'https://trove.b-cdn.net/images/kitchen.jpeg',
            'alt' => 'Heritage h-3260-32a kitchen home features', 'image_tags' => ['kitchen'] },
          # series-only alt — 38% of Legacy's models publish photos this way
          { 'image_url' => 'https://trove.b-cdn.net/images/bath.jpeg',
            'alt' => 'Heritage bathroom home features', 'image_tags' => ['bathroom'] },
          # a different series entirely
          { 'image_url' => 'https://trove.b-cdn.net/images/other-series.jpeg',
            'alt' => 'Oilfield hero and exterior home features', 'image_tags' => ['hero'] },
          # same series, DIFFERENT model — the case series-only matching must not swallow
          { 'image_url' => 'https://trove.b-cdn.net/images/sibling.jpeg',
            'alt' => 'Heritage h-3272-43a kitchen home features', 'image_tags' => ['kitchen'] }
        ]
      }.to_json
      "<html><body>#{flight_script(payload)}</body></html>"
    end

    before do
      allow(adapter).to receive(:http_get) do |url, **|
        case url
        when "#{base_url}/homes" then index_html
        when %r{/homes/legacy-housing-heritage-collection-h-3260-32a\z} then detail_html
        end
      end
    end

    it 'discovers products from the flight payload even when split across pushes' do
      expect(adapter.discover).to eq(['legacy-housing-heritage-collection-h-3260-32a'])
    end

    it 'builds the gallery from the detail page' do
      home = adapter.parse(adapter.fetch(adapter.discover.first))
      expect(home.image_source_urls).to include('https://trove.b-cdn.net/images/kitchen.jpeg')
    end

    # Legacy labels most galleries with the series alone. Requiring the full
    # model name loses those photos entirely.
    it 'keeps series-only alt text for this home' do
      home = adapter.parse(adapter.fetch(adapter.discover.first))
      expect(home.image_source_urls).to include('https://trove.b-cdn.net/images/bath.jpeg')
    end

    it "excludes another series' images" do
      home = adapter.parse(adapter.fetch(adapter.discover.first))
      expect(home.image_source_urls).not_to include('https://trove.b-cdn.net/images/other-series.jpeg')
    end

    # The reason series-only matching is bounded: once the word after the series
    # looks like a model number, it has to be OUR model number.
    it "excludes a sibling model from the same series" do
      home = adapter.parse(adapter.fetch(adapter.discover.first))
      expect(home.image_source_urls).not_to include('https://trove.b-cdn.net/images/sibling.jpeg')
    end

    it 'falls back to the index images when the detail page is unavailable' do
      allow(adapter).to receive(:http_get) { |url, **| url == "#{base_url}/homes" ? index_html : nil }
      home = adapter.parse(adapter.fetch(adapter.discover.first))
      expect(home.image_source_urls).to contain_exactly(
        'https://trove.b-cdn.net/images/plan.png', 'https://trove.b-cdn.net/images/hero.jpeg'
      )
    end

    it 'returns [] rather than raising when the index is unavailable' do
      allow(adapter).to receive(:http_get).and_return(nil)
      expect(adapter.discover).to eq([])
    end

    it 'honours the limit' do
      expect(adapter.discover(limit: 0)).to eq([])
    end

    # Admins paste the URL they were looking at. Without normalizing, a base of
    # ".../catalog" builds ".../catalog/homes" and discovers nothing, with no
    # obvious cause in the UI.
    ['https://trove.legacyhousing.com/catalog',
     'https://trove.legacyhousing.com/homes',
     'https://trove.legacyhousing.com/'].each do |pasted|
      it "normalizes a pasted base URL (#{pasted}) to the site root" do
        source.base_url = pasted
        expect(adapter.discover).to eq(['legacy-housing-heritage-collection-h-3260-32a'])
      end
    end
  end

  describe 'registry wiring' do
    let(:source) { build(:catalog_source, adapter_type: 'trove_catalog', base_url: base_url) }

    it 'resolves from the adapter type' do
      expect(Catalog::AdapterRegistry.for(source)).to be_a(described_class)
      expect(CatalogSource::ADAPTER_TYPES).to include('trove_catalog')
    end
  end
end
