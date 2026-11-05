# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('spec/support/fake_catalog_adapter')

RSpec.describe Catalog::IngestionService do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:source)  { create(:catalog_source) }

  def ingest(homes, **opts)
    described_class.new(company: company, source: source, **opts).call(homes)
  end

  it 'adds new homes as catalog-sourced vehicles without titleizing the model id' do
    result = ingest([FakeCatalogAdapter.home('1', model_name: 'PRI3284H')])

    expect(result.added).to eq(1)
    vehicle = company.vehicles.find_by(catalog_source_id: source.id, catalog_source_key: '1')
    expect(vehicle.source).to eq('catalog_import')
    expect(vehicle.listing_type).to eq('manufactured_home')
    expect(vehicle.status).to eq('available_to_order')
    expect(vehicle.model).to eq('PRI3284H') # catalog_import is exempt from titleize
    # Images MUST be stored in the {url, alt} shape the UI reads (the Champion
    # shape), not the NormalizedHome internal {source_url,...} shape.
    expect(vehicle.images.first).to include('url')
    expect(vehicle.images.first['url']).to start_with('http')
    expect(vehicle.photo_url).to eq(vehicle.images.first['url'])
    # Dimensions ("30'0\" x 80'0\"") parse into width/length feet for the UI.
    expect(vehicle.width).to eq(30)
    expect(vehicle.length).to eq(80)
  end

  it 'is idempotent — re-ingesting unchanged homes reports unchanged' do
    homes = [FakeCatalogAdapter.home('1')]
    ingest(homes)
    result = ingest(homes)

    expect(result.unchanged).to eq(1)
    expect(result.added).to eq(0)
  end

  it 'updates when content changes' do
    ingest([FakeCatalogAdapter.home('1', square_feet: 2000)])
    result = ingest([FakeCatalogAdapter.home('1', square_feet: 2500)])

    expect(result.updated).to eq(1)
    expect(company.vehicles.find_by(catalog_source_key: '1').square_feet).to eq(2500)
  end

  it 'inactivates homes missing from the run (never deletes)' do
    ingest([FakeCatalogAdapter.home('1'), FakeCatalogAdapter.home('2')])
    result = ingest([FakeCatalogAdapter.home('1')])

    expect(result.inactivated).to eq(1)
    gone = company.vehicles.unscoped.find_by(catalog_source_key: '2')
    expect(gone.is_deleted).to be(true)
  end

  # A site outage or a bot block yields no homes. That is a failed crawl, not a
  # manufacturer discontinuing its whole catalog.
  it 'keeps every home when a run has no homes at all' do
    ingest([FakeCatalogAdapter.home('1'), FakeCatalogAdapter.home('2')])
    result = ingest([])

    expect(result.inactivated).to eq(0)
    expect(company.vehicles.where(catalog_source_id: source.id, is_deleted: [false, nil]).count).to eq(2)
  end

  describe 'a run missing most of the catalog' do
    let(:keys) { %w[1 2 3 4 5] }
    let(:vehicles) { company.vehicles.where(catalog_source_id: source.id) }

    before { ingest(keys.map { |k| FakeCatalogAdapter.home(k) }) }

    it 'holds the missing homes and reports them' do
      result = ingest([FakeCatalogAdapter.home('1')])

      expect(result.held).to eq(4)
      expect(result.inactivated).to eq(0)
      expect(vehicles.where(is_deleted: [false, nil]).count).to eq(5)
    end

    it 'removes held homes once they have gone unseen for the whole hold' do
      vehicles.where.not(catalog_source_key: %w[1 2]).update_all(catalog_last_seen_at: 22.days.ago)

      result = ingest([FakeCatalogAdapter.home('1')])

      expect(result.inactivated).to eq(3)
      expect(result.held).to eq(1)
      expect(vehicles.where(is_deleted: [false, nil]).pluck(:catalog_source_key)).to contain_exactly('1', '2')
    end

    it 'still removes homes normally when half or fewer went missing' do
      result = ingest(%w[1 2 3].map { |k| FakeCatalogAdapter.home(k) })

      expect(result.inactivated).to eq(2)
      expect(result.held).to eq(0)
    end

    it 'does not count supplemented homes as missing' do
      vehicles.where(catalog_source_key: %w[2 3 4 5]).find_each do |vehicle|
        vehicle.update_columns(catalog_last_synced_values: { described_class::SUPPLEMENT_MARK => true })
      end

      result = ingest([FakeCatalogAdapter.home('1')])

      expect(result.held).to eq(0)
      expect(result.inactivated).to eq(0)
    end
  end

  describe 'a home with no bath count' do
    let(:no_baths) { FakeCatalogAdapter.home('1', bathrooms: nil) }

    it 'loads blank when the source declares it does not publish baths' do
      source.update!(config: { 'untracked_fields' => %w[bathrooms] })

      expect(ingest([no_baths]).added).to eq(1)
      expect(company.vehicles.find_by(catalog_source_key: '1').bathrooms).to be_nil
    end

    it 'is still refused from a source that does publish baths' do
      expect(ingest([no_baths]).added).to eq(0)
      expect(company.vehicles.find_by(catalog_source_key: '1')).to be_nil
    end

    it 'still requires baths on a home that is not from a catalog' do
      vehicle = company.vehicles.new(listing_type: 'manufactured_home', bathrooms: nil)
      vehicle.valid?
      expect(vehicle.errors[:bathrooms]).to be_present
    end
  end

  it 'does not overwrite populated fields with blanks when protect_blanks is set' do
    ingest([FakeCatalogAdapter.home('1', description: 'Original description')])
    ingest([FakeCatalogAdapter.home('1', description: nil, square_feet: 9999)], protect_blanks: true)

    vehicle = company.vehicles.find_by(catalog_source_key: '1')
    expect(vehicle.description).to eq('Original description')
    expect(vehicle.square_feet).to eq(9999)
  end

  describe 'building code' do
    def code_for(key) = company.vehicles.find_by(catalog_source_key: key).building_code

    it 'reads it from the property type the listing publishes' do
      ingest([FakeCatalogAdapter.home('1', property_type: ['Double Wide', 'Modular'])])
      expect(code_for('1')).to eq('MOD')
    end

    # Kabco's site says only "Double Wide"; it builds HUD homes and nothing else.
    it "falls back to the source's default when the listing never says" do
      source.update!(config: (source.config || {}).merge('default_building_code' => 'HUD'))
      ingest([FakeCatalogAdapter.home('1', property_type: ['Double Wide'])])
      expect(code_for('1')).to eq('HUD')
    end

    # Clayton and Legacy homes went in with no code; setting the source's
    # default afterwards scraped nothing new, so the next run skipped them.
    it "gives homes already in stock the default once it is set" do
      home = FakeCatalogAdapter.home('1', property_type: ['Double Wide'])
      ingest([home])
      expect(code_for('1')).to be_nil

      source.update!(config: (source.config || {}).merge('default_building_code' => 'HUD'))
      ingest([home])
      expect(code_for('1')).to eq('HUD')
    end

    it 'leaves it blank rather than guess' do
      ingest([FakeCatalogAdapter.home('1', property_type: ['Double Wide'])])
      expect(code_for('1')).to be_nil
    end
  end

  describe 'what a dealer did to a catalog home' do
    def row(key = '1') = company.vehicles.find_by(catalog_source_id: source.id, catalog_source_key: key)
    def home(key = '1', **attrs) = FakeCatalogAdapter.home(key, **attrs)
    let(:mine) { [{ 'url' => 'https://lot.example/mine.jpg' }] }

    it 'keeps photos the dealer added when the home is unchanged' do
      ingest([home])
      row.update_columns(images: mine, photo_url: mine.first['url'])

      expect(ingest([home]).unchanged).to eq(1)
      expect(row.reload.images).to eq(mine)
      expect(row.photo_url).to eq(mine.first['url'])
    end

    it 'keeps photos the dealer added when the home changes' do
      ingest([home])
      row.update_columns(images: mine, photo_url: mine.first['url'])
      ingest([home(square_feet: 2500)])

      expect(row.reload.images).to eq(mine)
      expect(row.square_feet).to eq(2500)
    end

    it 'keeps the order and cover the dealer chose' do
      pictures = [{ 'url' => 'https://cdn/1.jpg' }, { 'url' => 'https://cdn/2.jpg' }]
      with_two = home(images: pictures.map { |p| { 'source_url' => p['url'], 'alt' => '' } })
      ingest([with_two])
      row.update_columns(images: row.images.reverse, photo_url: 'https://cdn/2.jpg')
      ingest([with_two])

      expect(row.reload.images.map { |i| i['url'] }).to eq(%w[https://cdn/2.jpg https://cdn/1.jpg])
      expect(row.photo_url).to eq('https://cdn/2.jpg')
    end

    it 'still carries our own copy of a picture onto an untouched home, and records it' do
      ingest([home])
      source_url = row.images.first['url']
      rehosted = home
      rehosted.images = rehosted.images.map { |i| i.merge('local_url' => 'https://assets.example/copy.jpg') }
      ingest([rehosted])

      expect(row.reload.images.first['url']).to eq('https://assets.example/copy.jpg')
      expect(row.photo_url).to eq('https://assets.example/copy.jpg')
      expect(row.catalog_last_synced_values['images'].first['url']).to eq('https://assets.example/copy.jpg')
      expect(source_url).not_to eq('https://assets.example/copy.jpg')
    end

    it 'recognizes a copy made before last synced was recorded' do
      ingest([home])
      rehosted = home
      rehosted.images = rehosted.images.map { |i| i.merge('local_url' => 'https://assets.example/copy.jpg') }
      row.update_columns(images: [{ 'url' => 'https://assets.example/copy.jpg', 'alt' => '' }])
      ingest([rehosted])

      expect(row.reload.catalog_last_synced_values['images'].first['url']).to eq('https://assets.example/copy.jpg')
    end

    it 'keeps an upload the dealer added at the end, stored as a plain address' do
      ingest([home])
      row.update_columns(images: row.images + ['/uploads/2026/08/lot.jpg'])
      ingest([home])

      expect(row.reload.images.last).to eq('/uploads/2026/08/lot.jpg')
    end

    it 'never touches an edited copy, even after the home leaves the feed' do
      ingest([home, home('2'), home('3')])
      copy = VehicleCloneFromCatalogService.new(
        row, status: 'available_to_order', attributes: { model: 'Dealer Name', square_feet: 1999, sale_price: 123_456 }
      ).call

      ingest([home(square_feet: 2500, model_name: 'Factory Renamed'), home('2'), home('3')])
      expect(copy.reload).to have_attributes(model: 'Dealer Name', square_feet: 1999, status: 'available_to_order')
      expect(copy.sale_price.to_i).to eq(123_456)

      ingest([home('2'), home('3')])
      expect(copy.reload.is_deleted).not_to eq(true)
    end

    describe 'when the home leaves the feed' do
      before { ingest([home, home('2'), home('3')]) }

      def gone_after_sync
        ingest([home('2'), home('3')])
        Vehicle.unscoped.find_by(company_id: company.id, catalog_source_key: '1').is_deleted
      end

      it('removes an untouched home') { expect(gone_after_sync).to be(true) }

      it 'keeps a home with a status the dealer set' do
        row.update_columns(status: 'sold')
        expect(gone_after_sync).not_to be(true)
      end

      it 'keeps a home the dealer priced' do
        row.update_columns(sale_price: 99_000)
        expect(gone_after_sync).not_to be(true)
      end

      it 'keeps a home on a deal' do
        allow_any_instance_of(Vehicle).to receive(:has_dealer_activity?).and_return(true)
        expect(gone_after_sync).not_to be(true)
      end
    end
  end
end
