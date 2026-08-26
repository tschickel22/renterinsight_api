# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AiModel do
  describe '.for' do
    it 'returns the default model for each role' do
      expect(described_class.for(:classification)).to eq('claude-sonnet-4-6')
      expect(described_class.for(:generation)).to eq('claude-sonnet-4-6')
      expect(described_class.for(:refine)).to eq('claude-haiku-4-5')
      expect(described_class.for(:vision)).to eq('claude-sonnet-4-6')
      expect(described_class.for(:analysis)).to eq('claude-sonnet-4-6')
      expect(described_class.for(:concierge)).to eq('claude-haiku-4-5')
    end

    # Date-suffixed ids (the old claude-haiku-4-5-20251001 form) are a stale
    # convention: they resolve today and stop resolving without warning. Every AI
    # call site reads through this constant, so one bad id takes out a whole class
    # of work at once.
    it 'carries no date suffix on any model id' do
      dated = AiModel::DEFAULTS.select { |_role, id| id =~ /-\d{8}\z/ }

      expect(dated).to be_empty, "date-suffixed model ids: #{dated.inspect}"
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
