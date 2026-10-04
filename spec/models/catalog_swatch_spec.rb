# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CatalogSwatch do
  describe '.names_match?' do
    it 'never matches two different names of the same length' do
      [['ozark shadow', 'destin white'], ['nordic white', '9656 natural'], ['black weatherwood', 'glacier quartzite'],
       ['dogwood harvest', 'casper cashmere']].each do |a, b|
        expect(described_class.names_match?(a, b)).to be(false), "#{a} matched #{b}"
      end
    end

    it 'matches the same name, or a two-word name inside a longer one' do
      expect(described_class.names_match?('destin white', 'destin white')).to be(true)
      expect(described_class.names_match?('inhale gris', 'inhale gris ceramic')).to be(true)
      expect(described_class.names_match?('white', 'sunset falls white')).to be(false)
    end
  end

  it 'finds no sample for a finish the sheets do not show' do
    pool = [described_class.new(set_name: 'Vinyl Flooring', name: '9656 - Natural', hex: '#847358', image_url: 'x'),
            described_class.new(set_name: 'Shaker Style Cabinets', name: 'Destin White', hex: '#eff0e5', image_url: 'y')]
    expect(described_class.for_finish(manufacturer_id: 1, factory_id: nil, surface: 'Flooring', value: 'Nordic White (9662)', pool: pool)).to be_nil
    expect(described_class.for_finish(manufacturer_id: 1, factory_id: nil, surface: 'Cabinets', value: 'Ozark Shadow', pool: pool)).to be_nil
    expect(described_class.for_finish(manufacturer_id: 1, factory_id: nil, surface: 'Cabinets', value: 'Destin White', pool: pool)&.name).to eq('Destin White')
  end
end
