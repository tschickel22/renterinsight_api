# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Catalog::HomesSnapshot do
  let(:source) do
    build(:catalog_source, name: 'Adventure Homes', adapter_type: 'adventure_homes',
                           base_url: 'https://adventurehomes.net')
  end

  let(:home) do
    Catalog::NormalizedHome.new(
      source_key: '0663ls', source_url: 'https://adventurehomes.net/floorplan/0663ls/',
      model_name: '0663LS', model_id: '0663LS', series: 'Lakeside',
      property_type: ['HUD - Manufactured Homes'], bedrooms: 3, bathrooms: '2',
      dimensions: '32x66', square_feet: 1560,
      features: { 'Exterior' => ['LP Smartside Siding'] },
      images: [{ 'source_url' => 'https://adventurehomes.net/wp-content/uploads/a.jpg',
                 'is_floorplan' => true }],
      virtual_tour_url: 'https://discover.matterport.com/space/4fK17MgETcm'
    )
  end

  describe '.build' do
    it 'stamps the schema and the source it came from' do
      payload = described_class.build(source: source, homes: [home])

      expect(payload).to include(
        'schema' => described_class::SCHEMA,
        'adapter_type' => 'adventure_homes',
        'base_url' => 'https://adventurehomes.net',
        'source_name' => 'Adventure Homes',
        'home_count' => 1
      )
      expect(payload['homes'].first['model_name']).to eq('0663LS')
    end
  end

  describe 'round trip' do
    it 'restores a home whose content_hash still matches the original' do
      payload = described_class.build(source: source, homes: [home])
      described_class.write('adventure_homes', payload)

      stored = described_class.read('adventure_homes')
      restored = Catalog::NormalizedHome.from_h(stored['homes'].first)

      # This is what lets a re-capture update only what changed: a stored home
      # and a freshly crawled one have to hash identically.
      expect(restored.content_hash).to eq(home.content_hash)
      expect(restored.features).to eq(home.features)
      expect(restored.floorplan_images.size).to eq(1)
      expect(restored).to be_valid_smoke
    end
  end

  describe '.write' do
    it 'refuses a payload from a different snapshot format' do
      expect { described_class.write('x', { 'schema' => 'trove.catalog.snapshot/v1' }) }
        .to raise_error(ArgumentError, /unexpected snapshot schema/)
    end

    it 'refuses anything that is not a hash' do
      expect { described_class.write('x', 'nope') }.to raise_error(ArgumentError)
    end

    it 'overwrites the same key, which is how a refresh works' do
      described_class.write('k', described_class.build(source: source, homes: [home]))
      described_class.write('k', described_class.build(source: source, homes: [home, home]))
      expect(described_class.read('k')['homes'].size).to eq(2)
    end
  end

  describe '.keys' do
    it 'lists stored snapshots without colliding with Trove\'s' do
      described_class.write('adventure_homes', described_class.build(source: source, homes: [home]))
      Catalog::TroveSnapshot.write('legacy_housing',
                                   { 'schema' => Catalog::TroveSnapshot::SCHEMA, 'homes' => [] })

      expect(described_class.keys).to eq(['adventure_homes'])
      expect(Catalog::TroveSnapshot.keys).to eq(['legacy_housing'])
    end
  end

  describe '.delete' do
    # Deleting writes a nil value rather than dropping the row, so a naive
    # listing keeps offering the key with 0 homes.
    it 'stops listing a snapshot once deleted' do
      described_class.write('gone', described_class.build(source: source, homes: [home]))
      expect(described_class.keys).to include('gone')

      described_class.delete('gone')

      expect(described_class.keys).not_to include('gone')
      expect(described_class.exists?('gone')).to be(false)
    end
  end

  it 'reports nothing for an unknown key rather than raising' do
    expect(described_class.read('never_captured')).to be_nil
    expect(described_class.exists?('never_captured')).to be(false)
  end
end
