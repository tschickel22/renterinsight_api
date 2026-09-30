# frozen_string_literal: true

require 'rails_helper'

# Phase 0 of the MCP work: the Partner API had to be safe to build on first.
# Each block pins one hole that was open before this change.
RSpec.describe 'Partner API key hardening', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:creator) do
    User.create!(email: "c-#{SecureRandom.hex(4)}@example.com", first_name: 'C', last_name: 'R',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end

  def make_key(company_id: company.id, permissions: { 'leads' => %w[read] }, rate_limit: 1000)
    ApiKey.new(
      company_id: company_id, name: 'k', key: "ri_live_#{SecureRandom.hex(24)}",
      permissions: permissions, status: 'active', rate_limit: rate_limit,
      created_by_user_id: creator.id
    ).tap { |k| k.save!(validate: false) }
  end

  def auth(key)
    { 'Authorization' => "Bearer #{key.key}" }
  end

  describe 'key storage' do
    it 'persists only a digest and a preview, never the plaintext' do
      key = make_key
      plaintext = key.key

      row = ApiKey.connection.select_one("SELECT key, key_digest, key_preview FROM api_keys WHERE id = #{key.id}")
      expect(row['key']).to be_nil
      expect(row['key_digest']).to eq(Digest::SHA256.hexdigest(plaintext))
      expect(row['key_preview']).to eq("#{plaintext[0..11]}...#{plaintext[-4..]}")
      expect(ApiKey.find(key.id).key).to be_nil
    end

    it 'authenticates by digest' do
      get '/api/partner/v1/ping', headers: auth(make_key)
      expect(response).to have_http_status(:ok)
    end

    it 'still accepts a row written before the digest existed, and backfills it' do
      key = make_key
      plaintext = key.key
      key.update_columns(key: plaintext, key_digest: nil, key_preview: nil)

      get '/api/partner/v1/ping', headers: { 'Authorization' => "Bearer #{plaintext}" }

      expect(response).to have_http_status(:ok)
      expect(key.reload.key_digest).to eq(Digest::SHA256.hexdigest(plaintext))
    end

    it 'rejects an unknown key' do
      get '/api/partner/v1/ping', headers: { 'Authorization' => 'Bearer ri_live_nope' }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'blank permissions' do
    it 'refuses a key with no permissions instead of granting everything' do
      get '/api/partner/v1/leads', headers: auth(make_key(permissions: {}))
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'platform key without a company' do
    let(:platform_key) { make_key(company_id: nil) }

    it 'is refused on tenant endpoints' do
      get '/api/partner/v1/leads', headers: auth(platform_key)
      expect(response).to have_http_status(:bad_request)
      expect(JSON.parse(response.body)['error']).to include('X-Company-ID')
    end

    it 'still answers ping' do
      get '/api/partner/v1/ping', headers: auth(platform_key)
      expect(response).to have_http_status(:ok)
    end
  end

  describe 'request log' do
    it 'records each call with the status the caller got, without the query string' do
      key = make_key

      expect {
        get '/api/partner/v1/leads', params: { q: 'jane@example.com' }, headers: auth(key)
      }.to change(ApiRequestLog, :count).by(1)

      log = ApiRequestLog.last
      expect(log.api_key_id).to eq(key.id)
      expect(log.company_id).to eq(company.id)
      expect(log.http_method).to eq('GET')
      expect(log.path).to eq('/api/partner/v1/leads')
      expect(log.status).to eq(200)
    end

    it 'records refused calls too' do
      get '/api/partner/v1/leads', headers: { 'Authorization' => 'Bearer ri_live_nope' }
      expect(ApiRequestLog.last.status).to eq(401)
    end
  end

  describe 'rate limit' do
    it 'counts from the shared request log, so it holds across instances' do
      key = make_key(rate_limit: 2)
      2.times { ApiRequestLog.create!(api_key: key, http_method: 'GET', path: '/x', status: 200) }

      get '/api/partner/v1/ping', headers: auth(key)
      expect(response).to have_http_status(:too_many_requests)
    end

    it 'does not count refused calls, so a retrying client recovers' do
      key = make_key(rate_limit: 2)
      ApiRequestLog.create!(api_key: key, http_method: 'GET', path: '/x', status: 200)
      5.times { ApiRequestLog.create!(api_key: key, http_method: 'GET', path: '/x', status: 429) }

      get '/api/partner/v1/ping', headers: auth(key)
      expect(response).to have_http_status(:ok)
    end

    it 'forgets calls older than the window' do
      key = make_key(rate_limit: 1)
      ApiRequestLog.create!(api_key: key, http_method: 'GET', path: '/x', status: 200, created_at: 2.hours.ago)

      get '/api/partner/v1/ping', headers: auth(key)
      expect(response).to have_http_status(:ok)
    end
  end
end
