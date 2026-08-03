# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Messaging::ColorContrast do
  describe '.parse' do
    it 'reads six-digit hex with or without the hash' do
      expect(described_class.parse('#ffffff')).to eq([1.0, 1.0, 1.0])
      expect(described_class.parse('000000')).to eq([0.0, 0.0, 0.0])
    end

    it 'expands shorthand hex' do
      expect(described_class.parse('#fff')).to eq(described_class.parse('#ffffff'))
    end

    # Tenants paste whatever their designer gave them. Anything this cannot read has to be
    # rejected here rather than reaching a style attribute.
    it 'rejects anything that is not a hex colour' do
      ['rgba(0,0,0,0.4)', 'navy', '#12345', '', nil].each do |value|
        expect(described_class.parse(value)).to be_nil
      end
    end
  end

  describe '.contrast_ratio' do
    it 'reports the WCAG extremes' do
      expect(described_class.contrast_ratio('#ffffff', '#000000')).to be_within(0.01).of(21.0)
      expect(described_class.contrast_ratio('#777777', '#777777')).to be_within(0.01).of(1.0)
    end

    it 'is nil when either colour is unreadable' do
      expect(described_class.contrast_ratio('#ffffff', 'periwinkle')).to be_nil
    end
  end

  describe '.readable_text_on' do
    it 'puts light text on dark backgrounds and dark text on light ones' do
      expect(described_class.readable_text_on('#1f2937')).to eq('#ffffff')
      expect(described_class.readable_text_on('#ffffff')).to eq('#111827')
    end

    # Luminance is not brightness: pure green is far lighter to the eye than pure blue at the
    # same numeric value, and picking white text for it would be unreadable.
    it 'weights green over blue rather than averaging the channels' do
      expect(described_class.readable_text_on('#00ff00')).to eq('#111827')
      expect(described_class.readable_text_on('#0000ff')).to eq('#ffffff')
    end

    it 'assumes light when the colour cannot be read, matching the rendered default' do
      expect(described_class.readable_text_on('not-a-colour')).to eq('#111827')
    end
  end

  describe '.visible_against' do
    it 'keeps a colour that stands apart from the background' do
      expect(described_class.visible_against('#00aa55', '#ffffff')).to eq('#00aa55')
    end

    it 'replaces one that would disappear into it' do
      expect(described_class.visible_against('#fefefe', '#ffffff')).to eq('#111827')
    end

    it 'uses the caller fallback when given one' do
      expect(described_class.visible_against('#fefefe', '#ffffff', fallback: '#00aa55')).to eq('#00aa55')
    end
  end
end
