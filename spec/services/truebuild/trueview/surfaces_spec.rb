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

  describe '.describe' do
    it 'checks pulls as hardware, with the doors keeping their finish' do
      expect(described_class.describe('Cabinet pulls')).to include('pulls and knobs')
      expect(described_class.describe('Cabinets')).to include('cabinet doors, drawer fronts')
    end
  end
end
