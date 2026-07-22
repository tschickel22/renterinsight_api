# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AiModel do
  describe '.for' do
    it 'returns the default model for each role' do
      expect(described_class.for(:classification)).to eq('claude-sonnet-4-6')
      expect(described_class.for(:generation)).to eq('claude-sonnet-4-6')
      expect(described_class.for(:refine)).to eq('claude-haiku-4-5-20251001')
      expect(described_class.for(:vision)).to eq('claude-sonnet-4-6')
      expect(described_class.for(:analysis)).to eq('claude-sonnet-4-6')
    end

    it 'accepts string role names' do
      expect(described_class.for('generation')).to eq('claude-sonnet-4-6')
    end

    it 'prefers the per-role ENV override when set' do
      ENV['AI_MODEL_GENERATION'] = 'claude-sonnet-5'
      expect(described_class.for(:generation)).to eq('claude-sonnet-5')
      expect(described_class.for(:classification)).to eq('claude-sonnet-4-6')
    ensure
      ENV.delete('AI_MODEL_GENERATION')
    end

    it 'raises on an unknown role' do
      expect { described_class.for(:summarization) }.to raise_error(ArgumentError, /unknown AI model role/)
    end
  end
end
