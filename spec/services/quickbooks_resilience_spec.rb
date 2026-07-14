# frozen_string_literal: true

require 'rails_helper'
# Exception classes live in quickbooks/client.rb — force-load so the
# constant is resolvable in this spec.
require Rails.root.join('app/services/quickbooks/client').to_s

RSpec.describe 'QB resilience behaviors', type: :service do
  describe 'search_entities SQL escaping' do
    let(:api) do
      # Instantiate the API without a real connection by stubbing the
      # required entity setup on a bare Company.
      company = Company.create!(name: "C-#{SecureRandom.hex(4)}")
      company.update_column(:quickbooks_realm_id, 'test-realm')
      # Skip the constructor's token refresh by stubbing it.
      allow_any_instance_of(QuickbooksApiService).to receive(:initialize) do |instance, _entity|
        instance.instance_variable_set(:@access_token, 'test-token')
        instance.instance_variable_set(:@realm_id, 'test-realm')
        instance.instance_variable_set(:@entity, company)
      end
      QuickbooksApiService.new(company)
    end

    it 'raises on an unsafe identifier' do
      expect {
        api.search_entities('Customer; DROP TABLE users;--', {})
      }.to raise_error(ArgumentError, /Unsafe QB identifier/)
    end

    it 'raises on an unsafe field name' do
      expect {
        api.search_entities('Customer', { "Name'; DROP--" => 'x' })
      }.to raise_error(ArgumentError, /Unsafe QB identifier/)
    end

    it 'escapes embedded single quotes in values (does not raise)' do
      # Value can be arbitrary; we care that it's escaped, not identifier-checked.
      allow(api).to receive(:query).and_return({ 'QueryResponse' => {} })
      expect {
        api.search_entities('Customer', { Name: "O'Brien" })
      }.not_to raise_error
      expect(api).to have_received(:query) do |sql|
        expect(sql).to include("Name = 'O''Brien'")
      end
    end
  end

  describe 'rate-limit retry' do
    let(:company) { Company.create!(name: "C-#{SecureRandom.hex(4)}") }
    let(:api) do
      allow_any_instance_of(QuickbooksApiService).to receive(:initialize) do |instance, _entity|
        instance.instance_variable_set(:@access_token, 'test-token')
        instance.instance_variable_set(:@realm_id, 'test-realm')
        instance.instance_variable_set(:@entity, company)
      end
      QuickbooksApiService.new(company)
    end

    it 'retries 429 up to the configured limit, then re-raises' do
      # Fail every call with 429 → should hit limit and raise.
      allow(api).to receive(:sleep) # skip the actual delays in tests
      call_count = 0
      allow(HTTParty).to receive(:get) do
        call_count += 1
        double(code: 429, body: '', headers: {}, parsed_response: {})
      end

      expect { api.get('someendpoint') }.to raise_error(QuickbooksRateLimitError)
      # 1 initial attempt + RATE_LIMIT_RETRY_LIMIT retries
      expect(call_count).to eq(1 + QuickbooksApiService::RATE_LIMIT_RETRY_LIMIT)
    end
  end

  describe 'from_qb pagination with since filter' do
    let(:company) { Company.create!(name: "C-#{SecureRandom.hex(4)}") }
    let(:api) do
      allow_any_instance_of(QuickbooksApiService).to receive(:initialize) do |instance, _entity|
        instance.instance_variable_set(:@access_token, 'test-token')
        instance.instance_variable_set(:@realm_id, 'test-realm')
        instance.instance_variable_set(:@entity, company)
      end
      QuickbooksApiService.new(company)
    end

    it 'injects a WHERE MetaData.LastUpdatedTime clause when since is given' do
      seen_queries = []
      allow(api).to receive(:query) do |sql|
        seen_queries << sql
        { 'QueryResponse' => { 'Invoice' => [] } }
      end

      cutoff = Time.utc(2026, 1, 1, 0, 0, 0)
      api.get_all_entities('Invoice', since: cutoff)

      expect(seen_queries.first).to include("WHERE MetaData.LastUpdatedTime > '2026-01-01T00:00:00Z'")
    end

    it 'omits the WHERE clause when since is nil (first full pull)' do
      seen = []
      allow(api).to receive(:query) do |sql|
        seen << sql
        { 'QueryResponse' => { 'Invoice' => [] } }
      end

      api.get_all_entities('Invoice')
      expect(seen.first).not_to include('WHERE')
    end
  end
end
