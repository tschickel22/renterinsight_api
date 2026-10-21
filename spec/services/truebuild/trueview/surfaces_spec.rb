# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Truebuild::Trueview::Surfaces do
  describe '.category' do
    it 'reads a gable accent as the outside gable, not a wall inside' do
      expect(described_class.category('Gable accent')).to eq('gable cladding')
      expect(described_class.category('Gable cladding')).to eq('gable cladding')
      expect(described_class.category('Accent wall')).to eq('accent wall')
    end

    it 'outlines cabinet pulls with the cabinets' do
      expect(described_class.category('Cabinet pulls')).to eq('cabinets')
    end
  end

  describe '.strict_fit' do
    let(:slight_miss) { { 'fit' => 3, 'spills_onto' => 'none', 'spill_size' => 'none', 'misses' => 'a sliver by the dining table', 'miss_size' => 'slight' } }

    it 'passes a floor outline that leaves out only a slight, distant part' do
      expect(described_class.strict_fit('flooring', slight_miss)).to eq(described_class::MIN_FIT)
    end

    it 'still turns down a floor outline that clearly misses part of the floor' do
      expect(described_class.strict_fit('flooring', slight_miss.merge('miss_size' => 'clear'))).to eq(3)
      expect(described_class.strict_fit('flooring', slight_miss.merge('fit' => 2))).to eq(2)
    end

    it 'allows no miss on any other surface' do
      expect(described_class.strict_fit('cabinets', slight_miss.merge('fit' => 4))).to eq(3)
    end
  end

  describe '.describe' do
    it 'names the parts of a floor the painter used to leave out' do
      expect(described_class.describe('Flooring')).to include('the whole floor', 'far walls', 'island or vanity')
    end


    it 'checks pulls as hardware, with the doors keeping their finish' do
      expect(described_class.describe('Cabinet pulls')).to include('pulls and knobs')
      expect(described_class.describe('Cabinets')).to include('cabinet doors, drawer fronts')
    end
  end
end
