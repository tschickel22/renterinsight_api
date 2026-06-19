# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::Admin::CatalogSources', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }

  def user_with(role)
    User.create!(
      email: "u-#{SecureRandom.hex(4)}@example.com",
      first_name: 'Tom', last_name: 'Schickel',
      password: 'Pass1234!', company_id: company.id, role: role
    )
  end

  def headers_for(user)
    token = JsonWebToken.encode(user_id: user.id, company_id: company.id)
    { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' }
  end

  let(:admin_headers)   { headers_for(user_with('platform_admin')) }
  let(:regular_headers) { headers_for(user_with('sales')) }

  describe 'authorization' do
    it 'rejects non-platform-admins' do
      get '/api/admin/catalog_sources', headers: regular_headers
      expect(response).to have_http_status(:forbidden)
    end

    it 'rejects unauthenticated requests' do
      get '/api/admin/catalog_sources'
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'GET index' do
    it 'returns sources with stats tiles' do
      create(:catalog_source, name: 'Sunshine', enabled: true)
      create(:catalog_source, name: 'Kabco', adapter_type: 'avada_sitemap')

      get '/api/admin/catalog_sources', headers: admin_headers
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['items'].size).to eq(2)
      expect(body['stats']).to include('total' => 2, 'enabled' => 1)
    end
  end

  describe 'POST create' do
    it 'creates a source (company_id never permitted)' do
      payload = { catalog_source: {
        name: 'Sunshine Homes', adapter_type: 'manufacturedhomes_platform',
        base_url: 'https://www.manufacturedhomes.com', manufacturer_id: '2459',
        config: { manufacturer_name: 'Sunshine' }
      } }
      expect do
        post '/api/admin/catalog_sources', params: payload.to_json, headers: admin_headers
      end.to change(CatalogSource, :count).by(1)
      expect(response).to have_http_status(:created)
    end

    it 'rejects an unknown adapter_type' do
      payload = { catalog_source: { name: 'X', adapter_type: 'mystery' } }
      post '/api/admin/catalog_sources', params: payload.to_json, headers: admin_headers
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe 'PATCH update — enable gating' do
    it 'refuses to enable a source that has not passed a clean run' do
      source = create(:catalog_source, enabled: false, last_run_status: 'never_run')
      patch "/api/admin/catalog_sources/#{source.id}",
            params: { catalog_source: { enabled: true } }.to_json, headers: admin_headers
      expect(response).to have_http_status(:unprocessable_entity)
      expect(source.reload.enabled).to be(false)
    end

    it 'allows enabling after a clean run' do
      source = create(:catalog_source, enabled: false, last_run_status: 'success')
      create(:scrape_run, catalog_source: source, status: 'success', degraded: false)
      patch "/api/admin/catalog_sources/#{source.id}",
            params: { catalog_source: { enabled: true } }.to_json, headers: admin_headers
      expect(response).to have_http_status(:ok)
      expect(source.reload.enabled).to be(true)
    end
  end

  describe 'POST run_now' do
    it 'enqueues a run job' do
      source = create(:catalog_source)
      expect do
        post "/api/admin/catalog_sources/#{source.id}/run_now", headers: admin_headers
      end.to have_enqueued_job(CatalogSourceRunJob)
      expect(response).to have_http_status(:accepted)
    end
  end

  describe 'GET runs' do
    it 'returns scrape-run history' do
      source = create(:catalog_source)
      create(:scrape_run, catalog_source: source)
      get "/api/admin/catalog_sources/#{source.id}/runs", headers: admin_headers
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['items'].size).to eq(1)
    end
  end
end
