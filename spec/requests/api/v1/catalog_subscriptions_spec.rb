# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::CatalogSubscriptions', type: :request do
  let(:company)       { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:other_company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }

  def user_for(co)
    User.create!(
      email: "u-#{SecureRandom.hex(4)}@example.com",
      first_name: 'T', last_name: 'U',
      password: 'Pass1234!', company_id: co.id, role: 'sales'
    )
  end

  def headers_for(co)
    token = JsonWebToken.encode(user_id: user_for(co).id, company_id: co.id)
    { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' }
  end

  let(:headers)       { headers_for(company) }
  let(:other_headers) { headers_for(other_company) }

  # enabled + last run succeeded cleanly => selectable_for_dealers? == true
  def selectable_source(name)
    source = create(:catalog_source, name: name, enabled: true, last_run_status: 'success')
    create(:scrape_run, catalog_source: source, status: 'success', degraded: false)
    source
  end

  describe 'GET index' do
    it 'returns only selectable+enabled sources and only this company\'s subscriptions' do
      good     = selectable_source('Sunshine')
      _disabled = create(:catalog_source, name: 'Off', enabled: false, last_run_status: 'success')
      _untested = create(:catalog_source, name: 'Untested', enabled: true, last_run_status: 'never_run')

      create(:dealer_catalog_subscription, company: company, catalog_source: good)
      create(:dealer_catalog_subscription, company: other_company, catalog_source: good)

      get '/api/v1/catalog_subscriptions', headers: headers
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)

      expect(body['availableSources'].map { |s| s['name'] }).to eq(['Sunshine'])
      expect(body['subscriptions'].size).to eq(1)
      expect(body['subscriptions'].first['catalogSourceId']).to eq(good.id)
    end
  end

  describe 'POST create' do
    it 'opts the company in' do
      source = selectable_source('Sunshine')
      expect do
        post '/api/v1/catalog_subscriptions',
             params: { catalog_subscription: { catalog_source_id: source.id } }.to_json,
             headers: headers
      end.to change(company.dealer_catalog_subscriptions, :count).by(1)
      expect(response).to have_http_status(:created)
      expect(JSON.parse(response.body)['subscription']['catalogSourceId']).to eq(source.id)
    end

    it 'is idempotent — opting in twice does not duplicate or 500' do
      source = selectable_source('Sunshine')
      payload = { catalog_subscription: { catalog_source_id: source.id } }.to_json

      post '/api/v1/catalog_subscriptions', params: payload, headers: headers
      expect(response).to have_http_status(:created)

      expect do
        post '/api/v1/catalog_subscriptions', params: payload, headers: headers
      end.not_to change(DealerCatalogSubscription, :count)
      expect(response).to have_http_status(:ok)
    end

    it 'rejects a non-selectable source with 422' do
      source = create(:catalog_source, name: 'Off', enabled: false, last_run_status: 'success')
      post '/api/v1/catalog_subscriptions',
           params: { catalog_subscription: { catalog_source_id: source.id } }.to_json,
           headers: headers
      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['error']).to match(/not available to dealers/)
    end

    it 'ignores a company_id in params and binds to the current company' do
      source = selectable_source('Sunshine')
      post '/api/v1/catalog_subscriptions',
           params: { catalog_subscription: { catalog_source_id: source.id, company_id: other_company.id } }.to_json,
           headers: headers
      expect(response).to have_http_status(:created)
      sub = DealerCatalogSubscription.find(JSON.parse(response.body)['subscription']['id'])
      expect(sub.company_id).to eq(company.id)
    end
  end

  describe 'DELETE destroy' do
    it 'removes the row and returns 204' do
      source = selectable_source('Sunshine')
      sub = create(:dealer_catalog_subscription, company: company, catalog_source: source)

      expect do
        delete "/api/v1/catalog_subscriptions/#{sub.id}", headers: headers
      end.to change(DealerCatalogSubscription, :count).by(-1)
      expect(response).to have_http_status(:no_content)
    end

    it 'does not let one company delete another company\'s subscription' do
      source = selectable_source('Sunshine')
      other_sub = create(:dealer_catalog_subscription, company: other_company, catalog_source: source)

      expect do
        delete "/api/v1/catalog_subscriptions/#{other_sub.id}", headers: headers
      end.not_to change(DealerCatalogSubscription, :count)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'auth' do
    it 'requires authentication' do
      get '/api/v1/catalog_subscriptions'
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
