# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Knowledge::IntentMatcher do
  # Build a lightweight stand-in for IntentPattern so tests don't need
  # a populated knowledge_intent_patterns table.
  let(:create_pattern) do
    ->(intent:, pattern:, priority: 0, entity: nil) do
      p = Knowledge::IntentPattern.new(
        pattern: pattern, intent_type: intent, priority: priority, entity_key: entity
      )
      # Stub #id for Result#pattern_id, and make #matches? use the real regex logic.
      allow(p).to receive(:id).and_return(SecureRandom.random_number(10_000))
      p
    end
  end

  let(:patterns) do
    [
      create_pattern.call(intent: 'create',   pattern: '\b(how (do|can) i|how to)\s+(create|add|make|new)\b', priority: 100),
      create_pattern.call(intent: 'delete',   pattern: '\b(how (do|can) i|how to)\s+(delete|remove)\b',        priority: 100),
      create_pattern.call(intent: 'explain',  pattern: '\b(what (is|are)|explain)\b',                          priority: 100),
      create_pattern.call(intent: 'navigate', pattern: '\b(where (is|can i find)|show me|go to|open)\b',       priority: 100)
    ]
  end

  let(:module_relation) { double('ActiveRecord::Relation', exists?: true) }
  let(:module_keys)     { %w[leads deals invoices] }

  before do
    # IntentMatcher calls Knowledge::IntentPattern.ordered_by_priority
    allow(Knowledge::IntentPattern).to receive(:ordered_by_priority).and_return(patterns)

    # detect_entity queries Knowledge::Module.active.pluck(:key) and
    # Knowledge::EntityAlias.pluck(...). Use plain doubles rather than
    # instance_double so we can stub Rails scopes that aren't real instance
    # methods on the relation class.
    active_modules = double('ActiveRecord::Relation')
    allow(active_modules).to receive(:pluck).with(:key).and_return(module_keys)
    allow(active_modules).to receive(:where).and_return(module_relation)
    allow(Knowledge::Module).to receive(:active).and_return(active_modules)

    allow(Knowledge::EntityAlias).to receive(:pluck).with(:alias_name, :canonical_key)
                                                    .and_return([
                                                      ['prospect',  'leads'],
                                                      ['customer',  'contacts'],
                                                      ['home',      'inventory'],
                                                      ['team member', 'users']
                                                    ])
  end

  describe '#parse' do
    it 'returns a create intent for "how do I create a new lead"' do
      result = described_class.new('how do I create a new lead').parse
      expect(result.intent).to eq('create')
      expect(result.entity).to eq('leads')
      expect(result.confidence).to be >= 0.7
    end

    it 'resolves alias-only queries to the canonical module' do
      result = described_class.new('show me homes').parse
      expect(result.entity).to eq('inventory')
      expect(result.intent).to eq('navigate')
    end

    it 'resolves multi-word aliases ("team member") to canonical key' do
      result = described_class.new('where is my team member list').parse
      expect(result.entity).to eq('users')
    end

    it 'detects delete intent' do
      result = described_class.new('how do I delete a lead').parse
      expect(result.intent).to eq('delete')
      expect(result.entity).to eq('leads')
    end

    it 'returns zero confidence on empty input' do
      expect(described_class.new('').parse.confidence).to eq(0.0)
      expect(described_class.new('   ').parse.confidence).to eq(0.0)
    end

    it 'returns intent even when no entity is in the query' do
      result = described_class.new('how do I create something').parse
      expect(result.intent).to eq('create')
      expect(result.entity).to be_nil
      expect(result.confidence).to eq(0.5)
    end

    it 'prefers canonical module over alias when both match' do
      result = described_class.new('go to leads').parse
      expect(result.entity).to eq('leads')
      expect(result.intent).to eq('navigate')
    end

    it 'handles invalid regex in a pattern without crashing' do
      bad = create_pattern.call(intent: 'create', pattern: '[unclosed(', priority: 500)
      allow(Knowledge::IntentPattern).to receive(:ordered_by_priority).and_return([bad] + patterns)
      expect { described_class.new('how do I create a lead').parse }.not_to raise_error
    end
  end

  describe 'Result struct' do
    it 'round-trips to a hash with the fields that got populated' do
      result = described_class.new('how do I create a new lead').parse
      hash   = result.to_h
      expect(hash).to include(intent: 'create', confidence: be > 0.0)
      expect(hash).to have_key(:matched_text)
    end
  end
end
