# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Knowledge::SmartSearchService do
  # We stub the whole knowledge graph (modules, features, articles, tours) so
  # these specs verify pipeline behavior without relying on seed data or a
  # populated database. Embedding/AI steps are never called in the happy path.

  let(:matcher_result) do
    Knowledge::IntentMatcher::Result.new(
      intent: 'create', entity: 'leads', confidence: 0.9, matched_text: 'how do I create a lead'
    )
  end

  let(:feature) do
    instance_double(Knowledge::Feature,
                    key: 'create', route: '/crm/leads/new', ui_selector: '#leads-new-button', name: 'Create Lead')
  end

  let(:leads_module) do
    m = double('Knowledge::Module', id: 1, key: 'leads', name: 'Leads', route: '/crm/leads')
    features_rel = double('ActiveRecord::Relation')
    # The service maps the user's intent to a feature key (create→create,
    # navigate→list). Accept any key — return the stub for 'create' and nil
    # for anything else so we still exercise the no-feature fallback path.
    allow(features_rel).to receive(:find_by) { |args| args[:key] == 'create' ? feature : nil }
    allow(m).to receive(:features).and_return(features_rel)
    m
  end

  before do
    allow(Knowledge::IntentMatcher).to receive(:new).and_return(
      instance_double(Knowledge::IntentMatcher, parse: matcher_result)
    )

    active_modules = double('ActiveRecord::Relation', find_by: leads_module)
    allow(Knowledge::Module).to receive(:active).and_return(active_modules)

    empty_ordered = double('ActiveRecord::Relation', first: nil)
    empty_where   = double('ActiveRecord::Relation', ordered: empty_ordered)
    active_tours  = double('ActiveRecord::Relation', where: empty_where)
    allow(Tour).to receive(:active).and_return(active_tours)

    articles_rel = double('ActiveRecord::Relation')
    allow(articles_rel).to receive(:where).and_return(articles_rel)
    allow(articles_rel).to receive(:ordered).and_return(articles_rel)
    allow(articles_rel).to receive(:limit).and_return([])
    allow(Knowledge::Article).to receive(:published).and_return(articles_rel)

    # SmartSearchService always records the search.
    allow(Knowledge::Search).to receive(:create!)
  end

  describe '#search' do
    it 'returns empty for blank query without writing analytics' do
      expect(Knowledge::Search).not_to receive(:create!)
      expect(described_class.new('').search).to eq([])
    end

    it 'returns a navigate result for a confident intent+entity match' do
      results = described_class.new('how do I create a lead').search
      expect(results.first).to include(
        type: 'navigate',
        module: 'leads',
        feature: 'create',
        route: '/crm/leads/new',
        selector: '#leads-new-button'
      )
    end

    it 'does not call the embedding service when step 3 produces a result' do
      expect(Knowledge::EmbeddingService).not_to receive(:generate)
      described_class.new('how do I create a lead').search
    end

    it 'escalates to step 4 (semantic) then step 5 (fallback) when graph returns nothing' do
      # Force matcher to produce a below-threshold result so feature lookup bails out.
      allow(Knowledge::IntentMatcher).to receive(:new).and_return(
        instance_double(Knowledge::IntentMatcher, parse: Knowledge::IntentMatcher::Result.new(
          intent: nil, entity: nil, confidence: 0.0, matched_text: 'gibberish'
        ))
      )
      stub_alias_miss
      allow(Knowledge::EmbeddingService).to receive(:generate).and_return(nil)

      results = described_class.new('gibberish').search
      expect(results.first[:type]).to eq('suggestion')
      expect(results.first[:source]).to eq('fallback')
    end

    it 'uses the alias step when the query is a bare synonym' do
      allow(Knowledge::IntentMatcher).to receive(:new).and_return(
        instance_double(Knowledge::IntentMatcher, parse: Knowledge::IntentMatcher::Result.new(
          intent: nil, entity: nil, confidence: 0.0, matched_text: 'home'
        ))
      )
      alias_hit = double('Knowledge::EntityAlias', canonical_key: 'leads')
      stub_alias_hit(alias_hit)

      results = described_class.new('home').search
      expect(results.first[:type]).to eq('navigate')
    end

    it 'persists a knowledge_searches row even when the query yields no results' do
      allow(Knowledge::IntentMatcher).to receive(:new).and_return(
        instance_double(Knowledge::IntentMatcher, parse: Knowledge::IntentMatcher::Result.new(
          intent: nil, entity: nil, confidence: 0.0, matched_text: 'gibberish'
        ))
      )
      stub_alias_miss
      allow(Knowledge::EmbeddingService).to receive(:generate).and_return(nil)

      expect(Knowledge::Search).to receive(:create!).with(hash_including(
        query: 'gibberish', intent_detected: nil, result_count: 1
      ))
      described_class.new('gibberish').search
    end

    def stub_alias_miss
      chain = double('ActiveRecord::Relation')
      allow(chain).to receive(:order).and_return(double('ActiveRecord::Relation', first: nil))
      allow(Knowledge::EntityAlias).to receive(:where).and_return(chain)
    end

    def stub_alias_hit(hit)
      chain = double('ActiveRecord::Relation')
      allow(chain).to receive(:order).and_return(double('ActiveRecord::Relation', first: hit))
      allow(Knowledge::EntityAlias).to receive(:where).and_return(chain)
    end
  end
end
