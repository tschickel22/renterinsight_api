# frozen_string_literal: true

require 'rails_helper'

# What a listing card says it is.
#
# A source is named for the operator who manages it, and that name was written
# straight onto every home's make: "2026 Clayton — Acme Homes, Llc (Monroe, NC)
# EMILIE ELITE". Asked where the Monroe address came from, the answer was that
# it is not an address at all — it is the retailer's city, inside the make.
RSpec.describe Catalog::ManufacturerName do
  def source(name, adapter: 'clayton_retail_home_center', config: {})
    CatalogSource.new(name: name, adapter_type: adapter, config: config)
  end

  it 'names the manufacturer, not the retailer the feed belongs to' do
    expect(described_class.for(source('Clayton — Acme Homes, Llc (Monroe, NC)'))).to eq('Clayton')
  end

  it 'leaves a name that is already just a manufacturer alone' do
    expect(described_class.for(source('Adventure Homes', adapter: 'adventure_homes')))
      .to eq('Adventure Homes')
  end

  it 'honours what an admin set on the source' do
    src = source('Clayton — Acme Homes', config: { 'manufacturer_name' => 'Clayton Homes' })

    expect(described_class.for(src)).to eq('Clayton Homes')
  end

  # Cavco publishes a brand per home, which beats anything we could infer.
  it 'prefers a brand the feed itself publishes' do
    expect(described_class.for(source('Cavco — Auburn', adapter: 'cavco_retailer'), brand: 'Fleetwood'))
      .to eq('Fleetwood')
  end

  it 'knows the manufacturer each single-builder adapter was written for' do
    {
      'clayton_epic_region' => 'Clayton',
      'cavco_retailer' => 'Cavco',
      'champion_feed' => 'Champion',
      'timber_creek_dealer' => 'Timber Creek'
    }.each do |adapter, expected|
      expect(described_class.for(source('Whatever The Operator Called It', adapter: adapter)))
        .to eq(expected), "#{adapter} named the source instead"
    end
  end

  # These adapters carry homes from many builders, so the source name is the
  # only clue there is.
  it 'falls back to the label for an adapter that names no manufacturer' do
    expect(described_class.for(source('Trove — Sunshine Homes', adapter: 'trove_catalog')))
      .to eq('Trove')
  end

  it 'cuts at every separator our own source names use' do
    [
      ['Clayton — Acme Homes', 'Clayton'],
      ['Clayton – Acme Homes', 'Clayton'],
      ['Clayton | Acme Homes', 'Clayton'],
      ['Clayton - Acme Homes', 'Clayton'],
      ['Clayton (Monroe, NC)', 'Clayton'],
      ['Clayton, Llc', 'Clayton'],
      ['Clayton / Monroe', 'Clayton']
    ].each do |name, expected|
      expect(described_class.for(source(name, adapter: 'trove_catalog'))).to eq(expected), name
    end
  end

  # A make is required on the vehicle, so this can never answer with nothing.
  it 'answers with something even when there is nothing to work with' do
    expect(described_class.for(source('—', adapter: 'trove_catalog'))).to eq('—')
  end
end
