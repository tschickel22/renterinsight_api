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

  describe '.main_parts' do
    it 'drops a patch painted apart from the floor, and keeps the floor' do
      mask = Vips::Image.black(100, 100).draw_rect(255, 0, 60, 100, 40, fill: true).draw_rect(255, 45, 10, 6, 10, fill: true)
      kept = described_class.main_parts(mask)
      expect(kept.getpoint(50, 80).first).to eq(255)
      expect(kept.getpoint(47, 14).first).to eq(0)
    end
  end

  describe '.find!' do
    it 'paints a floor with Lite on every try' do
      photo = Vips::Image.black(40, 30, bands: 3).copy(interpretation: :srgb).jpegsave_buffer
      magenta = (Vips::Image.black(40, 30, bands: 3) + [255, 0, 255]).cast(:uchar).copy(interpretation: :srgb).pngsave_buffer
      painted = []
      allow(Truebuild::Trueview::Providers::Gemini).to receive(:edit) do |spec, *|
        painted << spec
        { bytes: magenta, usage: {}, model: spec[:model] }
      end
      allow(described_class).to receive(:check).and_return('present' => true, 'fit' => 2) # turned down each time
      allow(Truebuild::Trueview).to receive(:store_bytes).and_return('https://b/m.png')
      described_class.find!('https://x/kitchen.jpg', photo, 'flooring')
      expect(painted).to eq([Truebuild::Trueview::MODELS.fetch('nb2-lite')] * 3)
    end
  end

  describe '.describe' do
    it 'names the parts of a floor the painter used to leave out' do
      expect(described_class.describe('Flooring')).to include('the whole floor', 'far walls', 'island or vanity', 'Not doors')
    end


    it 'checks pulls as hardware, with the doors keeping their finish' do
      expect(described_class.describe('Cabinet pulls')).to include('pulls and knobs')
      expect(described_class.describe('Cabinets')).to include('cabinet doors, drawer fronts')
    end
  end
end
