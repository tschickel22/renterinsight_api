# frozen_string_literal: true

require 'rails_helper'

RSpec.describe WorkflowEngine::ConditionEvaluator do
  describe '.evaluate' do
    it 'returns true for blank conditions' do
      expect(described_class.evaluate(nil, {})).to eq(true)
      expect(described_class.evaluate([], {})).to eq(true)
      expect(described_class.evaluate({}, {})).to eq(true)
    end

    context 'tag operators' do
      let(:string_tags_ctx) { { 'tags' => %w[hot_lead vip] } }
      let(:hash_tags_ctx)   { { 'tags' => [{ 'id' => 1, 'name' => 'hot_lead' }, { 'id' => 2, 'name' => 'vip' }] } }
      let(:object_tags_ctx) do
        tag_struct = Struct.new(:id, :name)
        { 'tags' => [tag_struct.new(1, 'hot_lead'), tag_struct.new(2, 'vip')] }
      end

      it 'tags_include returns true when record has the tag (string array)' do
        leaf = { 'field' => 'tags', 'operator' => 'tags_include', 'value' => 'hot_lead' }
        expect(described_class.evaluate(leaf, string_tags_ctx)).to eq(true)
      end

      it 'tags_include returns false when tag is missing' do
        leaf = { 'field' => 'tags', 'operator' => 'tags_include', 'value' => 'cold_lead' }
        expect(described_class.evaluate(leaf, string_tags_ctx)).to eq(false)
      end

      it 'tags_include matches by name on hash entries' do
        leaf = { 'field' => 'tags', 'operator' => 'tags_include', 'value' => 'vip' }
        expect(described_class.evaluate(leaf, hash_tags_ctx)).to eq(true)
      end

      it 'tags_include matches by id when value is an integer' do
        leaf = { 'field' => 'tags', 'operator' => 'tags_include', 'value' => 1 }
        expect(described_class.evaluate(leaf, hash_tags_ctx)).to eq(true)
      end

      it 'tags_include matches against objects responding to name' do
        leaf = { 'field' => 'tags', 'operator' => 'tags_include', 'value' => 'hot_lead' }
        expect(described_class.evaluate(leaf, object_tags_ctx)).to eq(true)
      end

      it 'tags_exclude is the inverse of tags_include' do
        leaf = { 'field' => 'tags', 'operator' => 'tags_exclude', 'value' => 'hot_lead' }
        expect(described_class.evaluate(leaf, string_tags_ctx)).to eq(false)
        leaf2 = { 'field' => 'tags', 'operator' => 'tags_exclude', 'value' => 'cold_lead' }
        expect(described_class.evaluate(leaf2, string_tags_ctx)).to eq(true)
      end

      it 'tags_any_of returns true if any of the listed tags match' do
        leaf = { 'field' => 'tags', 'operator' => 'tags_any_of', 'value' => %w[cold_lead vip] }
        expect(described_class.evaluate(leaf, string_tags_ctx)).to eq(true)
      end

      it 'tags_any_of returns false if none of the listed tags match' do
        leaf = { 'field' => 'tags', 'operator' => 'tags_any_of', 'value' => %w[cold_lead nurture] }
        expect(described_class.evaluate(leaf, string_tags_ctx)).to eq(false)
      end

      it 'tag operators return false when tags is nil' do
        leaf = { 'field' => 'tags', 'operator' => 'tags_include', 'value' => 'hot_lead' }
        expect(described_class.evaluate(leaf, { 'tags' => nil })).to eq(false)
        leaf2 = { 'field' => 'tags', 'operator' => 'tags_any_of', 'value' => %w[hot_lead] }
        expect(described_class.evaluate(leaf2, { 'tags' => nil })).to eq(false)
      end

      it 'tags_exclude returns true when tags is nil (no tag means tag is excluded)' do
        leaf = { 'field' => 'tags', 'operator' => 'tags_exclude', 'value' => 'hot_lead' }
        expect(described_class.evaluate(leaf, { 'tags' => nil })).to eq(true)
      end
    end
  end
end
