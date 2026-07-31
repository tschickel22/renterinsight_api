# frozen_string_literal: true

require 'rails_helper'

# Cavco genuinely knows what is on a dealer's lot, so onboarding seeds their
# actual homes rather than only the orderable menu. These are real dealer
# vehicles with real statuses — NOT catalog rows, which the codebase requires
# to sit at available_to_order and excludes from inventory counts.
RSpec.describe Catalog::CavcoInventorySeeder do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:source)  { create(:catalog_source, adapter_type: 'cavco_retailer', name: 'Cavco - Amarillo') }
  let(:seeder)  { described_class.new(company: company, source: source) }

  def unit(overrides = {})
    {
      'id' => '586175f5-61b9-4dcf-b2e4-b20b0696ac31',
      'name' => 'Matrix', 'model_number' => '30724X',
      'brand_name' => 'Cavco - Fort Worth',
      'inventory_availability' => 'Available', 'inventory_type' => 'Stock',
      'sale_type' => 'New', 'sections' => 'Double-wide',
      'number_of_bedrooms' => 4.0, 'number_of_bathrooms' => 3.0, 'square_foot' => 2160.0,
      'selling_price' => 'Call for Pricing',
      'ship_date' => '2025-05-15T22:00:00+00:00',
      '3d_tour' => 'https://my.matterport.com/show/?m=qpiFR7QYzmQ',
      'photos' => [{ 'url' => 'https://cdn2.cavco.com/public/phhweb/a.jpg', 'alt' => 'front' }].to_json,
      'type' => 'inventory'
    }.merge(overrides)
  end

  describe 'seeding' do
    it 'creates a real dealer vehicle, not a catalog row' do
      expect(seeder.call([unit]).created).to eq(1)

      v = company.vehicles.last
      expect(v.source).to eq('catalog_inventory')
      expect(v.catalog_row?).to be(false)
      expect(v.status).to eq('available')
    end

    # Catalog rows are excluded from in_inventory by design; seeded homes are
    # the dealer's actual stock and must count.
    it 'counts as inventory' do
      seeder.call([unit])
      expect(company.vehicles.in_inventory.count).to eq(1)
    end

    it 'maps the specs Cavco publishes' do
      seeder.call([unit])
      v = company.vehicles.last
      expect([v.bedrooms, v.bathrooms, v.square_feet]).to eq([4, 3, 2160])
      expect(v.model).to eq('Matrix 30724X')
      expect(v.make).to eq('Cavco - Fort Worth')
    end

    # Inventory documents carry no width/length fields at all.
    it 'takes dimensions from the model number, the only size Cavco gives here' do
      seeder.call([unit])
      v = company.vehicles.last
      expect([v.width, v.length]).to eq([30, 72])
    end

    it 'keeps photos and the tour' do
      seeder.call([unit])
      v = company.vehicles.last
      expect(v.images.map { |i| i['url'] }).to eq(['https://cdn2.cavco.com/public/phhweb/a.jpg'])
      expect(v.virtual_tour_url).to include('matterport.com')
    end

    # ~90% of selling_price is "Call for Pricing", the rest marketing copy.
    it 'never turns the free-text price into a number' do
      seeder.call([unit('selling_price' => 'Sizzlin Summer SALE!!!')])
      v = company.vehicles.last
      expect(v.sale_price).to be_nil
      expect(v.notes).to include('Sizzlin Summer SALE!!!')
    end

    it 'marks pre-owned units used' do
      seeder.call([unit('sale_type' => 'Pre-owned')])
      expect(company.vehicles.last.condition).to eq('used')
    end
  end

  describe 'status mapping' do
    {
      'Available' => 'available', 'Priced To Move' => 'available',
      'Display Home' => 'available', 'Under Contract' => 'pending', 'Sold' => 'sold'
    }.each do |cavco, expected|
      it "maps #{cavco} to #{expected}" do
        seeder.call([unit('inventory_availability' => cavco)])
        expect(company.vehicles.last.status).to eq(expected)
      end
    end

    it 'falls back to available on an unknown value' do
      expect(described_class.status_for('Something New')).to eq('available')
    end
  end

  # The case that matters most: we import a pending home, the dealer sells it,
  # and Cavco is slow to catch up and still reports it pending.
  describe 'write-once identity' do
    it 'does not duplicate when the dealer has moved the home on' do
      seeder.call([unit('inventory_availability' => 'Under Contract')])
      vehicle = company.vehicles.last
      expect(vehicle.status).to eq('pending')

      vehicle.update!(status: 'sold')

      # Cavco still reporting the stale status.
      result = seeder.call([unit('inventory_availability' => 'Under Contract')])

      expect(result.created).to eq(0)
      expect(result.skipped_existing).to eq(1)
      expect(company.vehicles.count).to eq(1)
      expect(vehicle.reload.status).to eq('sold')
    end

    it 'is keyed on the Cavco UUID, not on anything that can change' do
      seeder.call([unit])
      result = seeder.call([unit('inventory_availability' => 'Sold',
                                 'selling_price' => '$109,900',
                                 'number_of_bedrooms' => 9.0)])

      expect(result.skipped_existing).to eq(1)
      expect(company.vehicles.count).to eq(1)
      expect(company.vehicles.last.bedrooms).to eq(4)
    end

    it 'still seeds a genuinely different unit' do
      seeder.call([unit])
      expect(seeder.call([unit('id' => 'a-different-uuid')]).created).to eq(1)
      expect(company.vehicles.count).to eq(2)
    end

    it 'skips a document with no id rather than creating an unidentifiable row' do
      expect(seeder.call([unit('id' => '')]).skipped_unmappable).to eq(1)
      expect(company.vehicles.count).to eq(0)
    end
  end

  # A floorplan run must not treat seeded homes as catalog rows that vanished.
  describe 'protection from the catalog tombstoning path' do
    it 'survives an ingestion run that does not mention it' do
      seeder.call([unit])
      vehicle = company.vehicles.last

      Catalog::IngestionService.new(company: company, source: source).call([])

      expect(vehicle.reload.is_deleted).to be_falsey
      expect(vehicle.status).to eq('available')
    end
  end
end
