# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Audiences::AiBuilder do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:user)    { User.create!(email: "u-#{SecureRandom.hex(3)}@example.com", first_name: 'T', last_name: 'U', password: 'Pass1234!', company_id: company.id) }

  before { allow(ENV).to receive(:[]).and_call_original }

  def stub_claude_response(filter_tree, input_tokens: 800, output_tokens: 200, status: '200')
    body = {
      'content' => [{ 'type' => 'text', 'text' => filter_tree.to_json }],
      'usage' => { 'input_tokens' => input_tokens, 'output_tokens' => output_tokens }
    }.to_json
    response = instance_double(Net::HTTPResponse, code: status, body: body)
    http = instance_double(Net::HTTP)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:request).and_return(response)
    allow(Net::HTTP).to receive(:new).and_return(http)
    allow(ENV).to receive(:[]).with('ANTHROPIC_API_KEY').and_return('test-key')
  end

  describe '#generate' do
    let(:tree) { { 'type' => 'and', 'children' => [{ 'field' => 'status', 'operator' => 'equals', 'value' => 'qualified' }] } }

    it 'creates an AudienceAiGeneration with parsed filter_tree' do
      stub_claude_response(tree)
      gen = described_class.new(company: company, user: user).generate(prompt: 'qualified leads', source_type: 'Lead')
      expect(gen).to be_a(AudienceAiGeneration)
      expect(gen.generated_filter_tree['children'].first['field']).to eq('status')
      expect(gen.input_tokens).to eq(800)
      expect(gen.output_tokens).to eq(200)
      expect(gen.status).to eq('generated')
      expect(gen.source_type).to eq('Lead')
    end

    it 'logs to AiQueryLog with feature ai_audience_generate' do
      stub_claude_response(tree)
      expect {
        described_class.new(company: company, user: user).generate(prompt: 'X', source_type: 'Lead')
      }.to change { AiQueryLog.where(feature: 'ai_audience_generate').count }.by(1)
      log = AiQueryLog.where(feature: 'ai_audience_generate').last
      expect(log.cost_cents).to be > 0
      expect(log.module_key).to eq('campaigns')
    end

    it 'raises GenerationError on non-200' do
      stub_claude_response(tree, status: '500')
      expect {
        described_class.new(company: company, user: user).generate(prompt: 'X', source_type: 'Lead')
      }.to raise_error(described_class::GenerationError, /Claude API error/)
    end

    it 'raises GenerationError on invalid JSON' do
      body = { 'content' => [{ 'type' => 'text', 'text' => 'not json' }], 'usage' => {} }.to_json
      response = instance_double(Net::HTTPResponse, code: '200', body: body)
      http = instance_double(Net::HTTP)
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:read_timeout=)
      allow(http).to receive(:open_timeout=)
      allow(http).to receive(:request).and_return(response)
      allow(Net::HTTP).to receive(:new).and_return(http)
      allow(ENV).to receive(:[]).with('ANTHROPIC_API_KEY').and_return('test-key')
      expect {
        described_class.new(company: company, user: user).generate(prompt: 'X', source_type: 'Lead')
      }.to raise_error(described_class::GenerationError, /invalid JSON/)
    end

    it 'raises CreditLimitError when monthly cap reached' do
      allow(ENV).to receive(:[]).with('AI_AUDIENCE_MONTHLY_CREDIT').and_return('1')
      allow(ENV).to receive(:[]).with('ANTHROPIC_API_KEY').and_return('test-key')
      AiQueryLog.create!(company: company, user: user, feature: 'ai_audience_generate',
                         module_key: 'campaigns', execution_status: 'success')
      expect {
        described_class.new(company: company, user: user).generate(prompt: 'X', source_type: 'Lead')
      }.to raise_error(described_class::CreditLimitError)
    end

    it 'rejects unsupported source_type' do
      stub_claude_response(tree)
      expect {
        described_class.new(company: company, user: user).generate(prompt: 'X', source_type: 'Vehicle')
      }.to raise_error(described_class::GenerationError, /Unsupported source_type/)
    end
  end

  describe '#refine' do
    let(:tree) { { 'type' => 'and', 'children' => [{ 'field' => 'email', 'operator' => 'contains', 'value' => 'foo' }] } }

    it 'creates child generation linked to parent' do
      stub_claude_response(tree)
      parent = AudienceAiGeneration.create!(company: company, user: user, prompt: 'p', source_type: 'Lead',
                                             generated_filter_tree: { 'type' => 'and', 'children' => [] }, status: 'generated')
      child = described_class.new(company: company, user: user).refine(generation: parent, feedback: 'narrow it')
      expect(child.parent_generation_id).to eq(parent.id)
      expect(child.status).to eq('refined')
      expect(child.source_type).to eq('Lead')
    end
  end

  describe '#accept' do
    it 'creates Audience, computes initial estimate, marks generation accepted' do
      tree = { 'type' => 'and', 'children' => [] }
      generation = AudienceAiGeneration.create!(company: company, user: user, prompt: 'p', source_type: 'Lead',
                                                 generated_filter_tree: tree, status: 'generated')
      audience = described_class.new(company: company, user: user).accept(
        generation: generation, name: 'High intent leads', description: 'auto'
      )
      expect(audience).to be_persisted
      expect(audience.name).to eq('High intent leads')
      expect(audience.estimated_count).to eq(0)
      expect(audience.estimated_at).not_to be_nil
      expect(audience.generated_from_ai_generation_id).to eq(generation.id)
      expect(generation.reload.status).to eq('accepted')
      expect(generation.audience_id).to eq(audience.id)
    end
  end
end
