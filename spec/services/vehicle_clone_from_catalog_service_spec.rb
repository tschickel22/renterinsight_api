# frozen_string_literal: true

require 'rails_helper'

RSpec.describe VehicleCloneFromCatalogService do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:source)  { create(:catalog_source) }

  let(:catalog) do
    company.vehicles.create!(
      listing_type: 'manufactured_home',
      source: 'catalog_import',
      status: 'available_to_order',
      condition: 'new',
      make: 'Sunshine', model: 'PRI3284H', year: 2026,
      serial_number: "CAT-#{source.id}-101",
      bedrooms: 3, bathrooms: 2, square_feet: 2000,
      images: [{ 'url' => 'https://cdn/a.jpg', 'alt' => 'front' }],
      floor_plan_images: [{ 'url' => 'https://cdn/fp.jpg', 'alt' => 'plan' }],
      photo_url: 'https://cdn/a.jpg',
      catalog_source_id: source.id, catalog_source_key: '101'
    )
  end

  it 'clones a catalog_import row into a dealer-owned, editable copy' do
    clone = described_class.new(catalog, status: 'available', attributes: { 'sale_price' => 89_999 }).call

    expect(clone).to be_present
    expect(clone.source).to eq('catalog_import_clone')
    expect(clone.status).to eq('available')
    expect(clone.cloned_from_id).to eq(catalog.id)
    expect(clone.sale_price.to_f).to eq(89_999.0)
    # Model id preserved (not titleized) and images carried over.
    expect(clone.model).to eq('PRI3284H')
    expect(clone.images.first['url']).to eq('https://cdn/a.jpg')
    expect(clone.floor_plan_images.first['url']).to eq('https://cdn/fp.jpg')
    # Clone is decoupled from the catalog sync (won't be matched/tombstoned).
    expect(clone.catalog_source_id).to be_nil
    expect(clone.catalog_source_key).to be_nil
  end

  it 'leaves the catalog row untouched' do
    described_class.new(catalog, status: 'available', attributes: { 'sale_price' => 89_999 }).call
    catalog.reload
    expect(catalog.status).to eq('available_to_order')
    expect(catalog.sale_price).to be_nil
    expect(catalog.images.first['url']).to eq('https://cdn/a.jpg')
  end

  it 'rejects cloning to the catalog-only status' do
    service = described_class.new(catalog, status: 'available_to_order')
    expect(service.call).to be_nil
    expect(service.errors[:status].join).to match(/non-catalog status/)
  end
end
