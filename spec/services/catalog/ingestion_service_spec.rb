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

  it 'does not overwrite populated fields with blanks when protect_blanks is set' do
    ingest([FakeCatalogAdapter.home('1', description: 'Original description')])
    ingest([FakeCatalogAdapter.home('1', description: nil, square_feet: 9999)], protect_blanks: true)

    vehicle = company.vehicles.find_by(catalog_source_key: '1')
    expect(vehicle.description).to eq('Original description')
    expect(vehicle.square_feet).to eq(9999)
  end
end
