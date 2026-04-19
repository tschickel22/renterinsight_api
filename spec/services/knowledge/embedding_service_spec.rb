# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Knowledge::EmbeddingService do
  describe '.generate' do
    let(:fake_embedding) { Array.new(1536) { rand(-1.0..1.0) } }

    before do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('OPENAI_API_KEY').and_return('sk-test')
      allow(ENV).to receive(:fetch).with('OPENAI_EMBEDDINGS_MODEL', anything).and_return('text-embedding-3-small')
    end

    it 'returns nil on blank input without calling the API' do
      expect(Net::HTTP).not_to receive(:new)
      expect(described_class.generate('')).to be_nil
      expect(described_class.generate(nil)).to be_nil
      expect(described_class.generate('   ')).to be_nil
    end

    it 'returns nil and logs a warning when OPENAI_API_KEY is missing' do
      allow(ENV).to receive(:[]).with('OPENAI_API_KEY').and_return(nil)
      expect(Rails.logger).to receive(:warn).with(/OPENAI_API_KEY/)
      expect(described_class.generate('hello')).to be_nil
    end

    it 'parses the embedding out of a successful OpenAI response' do
      success = instance_double(Net::HTTPOK, is_a?: true, body: { data: [{ embedding: fake_embedding }] }.to_json)
      allow(success).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)

      http = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).and_return(http)
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:read_timeout=)
      allow(http).to receive(:request).and_return(success)

      result = described_class.generate('how do I create a lead')
      expect(result).to eq(fake_embedding)
      expect(result.length).to eq(1536)
    end

    it 'returns nil and logs on non-2xx responses' do
      fail_resp = instance_double(Net::HTTPInternalServerError, body: '{"error":"oops"}', code: '500')
      allow(fail_resp).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)

      http = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).and_return(http)
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:read_timeout=)
      allow(http).to receive(:request).and_return(fail_resp)

      expect(Rails.logger).to receive(:error).with(/OpenAI embeddings error 500/)
      expect(described_class.generate('x')).to be_nil
    end

    it 'swallows network errors and returns nil' do
      http = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).and_return(http)
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:read_timeout=)
      allow(http).to receive(:request).and_raise(SocketError, 'dns fail')

      expect(Rails.logger).to receive(:error).with(/SocketError/)
      expect(described_class.generate('x')).to be_nil
    end
  end

  describe '.search' do
    it 'returns an empty AR relation on blank embedding' do
      rel = described_class.search(nil)
      expect(rel).to respond_to(:to_a)
      expect(rel.to_a).to eq([])
    end

    it 'degrades gracefully when has_neighbors is not available' do
      # published.where.not(embedding: nil).nearest_neighbors(...) — stub the chain
      rel = double('ActiveRecord::Relation')
      where_chain = double('ActiveRecord::Relation')
      allow(rel).to receive(:where).and_return(where_chain)
      allow(where_chain).to receive(:not).with(embedding: nil).and_return(where_chain)
      allow(where_chain).to receive(:nearest_neighbors).and_raise(NoMethodError, 'not defined')
      allow(Knowledge::Article).to receive(:published).and_return(rel)
      allow(Knowledge::Article).to receive(:none).and_return('none_relation')

      expect(Rails.logger).to receive(:warn).with(/has_neighbors not available/)
      expect(described_class.search([0.1] * 1536)).to eq('none_relation')
    end
  end

  describe '.update_article' do
    it 'is a no-op if argument is not a Knowledge::Article' do
      expect(described_class.update_article(nil)).to be_nil
      expect(described_class.update_article('not an article')).to be_nil
    end

    it 'calls generate with concatenated title/excerpt/content and persists the vector' do
      article = instance_double(Knowledge::Article,
                                is_a?: true,
                                title: 'Create a lead',
                                excerpt: 'TL;DR',
                                content: 'Full how-to body…')
      allow(article).to receive(:is_a?).with(Knowledge::Article).and_return(true)

      vector = Array.new(1536) { 0.1 }
      expect(described_class).to receive(:generate).with(include('Create a lead')).and_return(vector)
      expect(article).to receive(:update_column).with(:embedding, vector)

      expect(described_class.update_article(article)).to eq(vector)
    end

    it 'returns nil if embedding generation fails' do
      article = instance_double(Knowledge::Article,
                                title: 't', excerpt: nil, content: nil)
      allow(article).to receive(:is_a?).with(Knowledge::Article).and_return(true)
      allow(described_class).to receive(:generate).and_return(nil)

      expect(article).not_to receive(:update_column)
      expect(described_class.update_article(article)).to be_nil
    end
  end
end
