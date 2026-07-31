# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::CatalogSubscriptions', type: :request do
  let(:company)       { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:other_company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }

  # Catalog assignment is platform-admin only: subscribing writes
  # available-to-order homes into a dealer's inventory at chosen locations, and
  # a wrong choice surfaces another manufacturer's homes to that location's
  # buyers. The company scoping below still matters — a platform admin acting
  # inside a tenant must not be able to reach another tenant's rows.
  def user_for(co, role: 'platform_admin')
    User.create!(
      email: "u-#{SecureRandom.hex(4)}@example.com",
      first_name: 'T', last_name: 'U',
      password: 'Pass1234!', company_id: co.id, role: role
    )
  end

  def headers_for(co, role: 'platform_admin')
    token = JsonWebToken.encode(user_id: user_for(co, role: role).id, company_id: co.id)
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

    it 'stores only the company\'s own locations and ignores foreign ones' do
      source  = selectable_source('Sunshine')
      mine    = company.locations.create!(name: 'Mine', timezone: 'UTC')
      foreign = other_company.locations.create!(name: 'Theirs', timezone: 'UTC')

      post '/api/v1/catalog_subscriptions',
           params: { catalog_subscription: { catalog_source_id: source.id,
                                             location_ids: [mine.id, foreign.id] } }.to_json,
           headers: headers
      expect(response).to have_http_status(:created)
      sub = DealerCatalogSubscription.find(JSON.parse(response.body)['subscription']['id'])
      expect(sub.location_ids).to eq([mine.id])
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

  # Dealer staff previously reached this with inventory:manage, so a rep could
  # attach any catalog to any of their locations. Hiding the tab alone would
  # not have stopped a direct call.
  describe 'access control' do
    let(:source) { selectable_source('Sunshine') }

    %w[sales admin company_admin].each do |role|
      it "rejects #{role} with 403" do
        get '/api/v1/catalog_subscriptions', headers: headers_for(company, role: role)
        expect(response).to have_http_status(:forbidden)
      end
    end

    it 'rejects a non-admin trying to subscribe directly' do
      post '/api/v1/catalog_subscriptions',
           params: { catalog_subscription: { catalog_source_id: source.id } }.to_json,
           headers: headers_for(company, role: 'admin')

      expect(response).to have_http_status(:forbidden)
      expect(DealerCatalogSubscription.count).to eq(0)
    end

    it 'rejects a non-admin trying to unsubscribe directly' do
      sub = DealerCatalogSubscription.create!(company: company, catalog_source: source, enabled: true)

      delete "/api/v1/catalog_subscriptions/#{sub.id}", headers: headers_for(company, role: 'admin')

      expect(response).to have_http_status(:forbidden)
      expect(DealerCatalogSubscription.exists?(sub.id)).to be(true)
    end

    it 'allows platform_admin' do
      get '/api/v1/catalog_subscriptions', headers: headers_for(company)
      expect(response).to have_http_status(:ok)
    end

    it 'allows super_admin' do
      get '/api/v1/catalog_subscriptions', headers: headers_for(company, role: 'super_admin')
      expect(response).to have_http_status(:ok)
    end
  end

  # Subscribing used to enqueue a FULL re-crawl just to backfill one dealer —
  # 716s for Kabco, 408s for Sunshine Homes, 375s for Clayton in production, for
  # data the source had already parsed.
  describe 'backfill on subscribe' do
    let(:source) { selectable_source('Sunshine') }

    def cached_home(key = 'model-a')
      Catalog::NormalizedHome.new(
        source_key: key, source_url: "https://example.com/homes/#{key}",
        model_name: 'The Colossal', model_id: 'ABC123', series: 'Heritage',
        property_type: ['Double Wide'], bedrooms: 3, bathrooms: 2,
        dimensions: '32x60', square_feet: 1600,
        images: [{ 'source_url' => 'https://cdn.example.com/a.jpg', 'is_floorplan' => false }]
      )
    end

    def subscribe!
      post '/api/v1/catalog_subscriptions',
           params: { catalog_subscription: { catalog_source_id: source.id } }.to_json,
           headers: headers
    end

    it 'ingests straight from cache instead of queueing a crawl' do
      Catalog::ParsedHomeCache.write(source, [cached_home])

      expect { subscribe! }.not_to have_enqueued_job(CatalogSourceRunJob)

      expect(JSON.parse(response.body).dig('backfill', 'mode')).to eq('cache')
      expect(company.vehicles.where(catalog_source_id: source.id).count).to eq(1)
    end

    it 'falls back to a crawl when nothing is cached' do
      expect { subscribe! }.to have_enqueued_job(CatalogSourceRunJob)
      expect(JSON.parse(response.body).dig('backfill', 'mode')).to eq('crawl_queued')
    end

    # Homes parsed under different settings are worse than no cache.
    it 'crawls rather than serving a cache from different source settings' do
      Catalog::ParsedHomeCache.write(source, [cached_home])
      source.update!(base_url: 'https://changed.example.com')

      expect { subscribe! }.to have_enqueued_job(CatalogSourceRunJob)
    end

    # Weekly sources keep their parse for the full week, so a day-3 subscribe
    # reuses it rather than paying a full crawl for barely newer data.
    it 'reuses the parse within the schedule window' do
      source.update!(schedule: 'weekly')
      Catalog::ParsedHomeCache.write(source, [cached_home])

      travel_to(3.days.from_now) do
        expect { subscribe! }.not_to have_enqueued_job(CatalogSourceRunJob)
      end
    end

    it 'crawls once the parse is older than the schedule window' do
      source.update!(schedule: 'weekly')
      Catalog::ParsedHomeCache.write(source, [cached_home])

      travel_to(8.days.from_now) do
        expect { subscribe! }.to have_enqueued_job(CatalogSourceRunJob)
      end
    end

    # Never leave a dealer subscribed to an empty inventory.
    it 'falls back to a crawl if cache ingestion blows up' do
      Catalog::ParsedHomeCache.write(source, [cached_home])
      allow(Catalog::SubscriptionIngestor).to receive(:call).and_raise(StandardError, 'boom')

      expect { subscribe! }.to have_enqueued_job(CatalogSourceRunJob)
      expect(JSON.parse(response.body).dig('backfill', 'mode')).to eq('crawl_queued')
    end
  end
end
