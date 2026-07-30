# frozen_string_literal: true

require 'rails_helper'

# Surface B — the "Add Clayton Dealer" flow. Platform admin picks a retailer by
# name from Clayton's national directory; name/base_url/config are derived so a
# base_url can't be mistyped. Enabling for a location stays the existing
# DealerCatalogSubscription flow.
RSpec.describe 'Api::Admin::CatalogSources Clayton dealer picker', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }

  def user_with(role)
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com",
                 first_name: 'Tom', last_name: 'Schickel',
                 password: 'Pass1234!', company_id: company.id, role: role)
  end

  def headers_for(user)
    token = JsonWebToken.encode(user_id: user.id, company_id: company.id)
    { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' }
  end

  let(:admin_headers)   { headers_for(user_with('platform_admin')) }
  let(:regular_headers) { headers_for(user_with('sales')) }

  let(:mhm) do
    { 'slug' => 'mobile-home-masters-inc', 'name' => 'Mobile Home Masters Inc',
      'dealer_id' => 757_055, 'dealer_number' => '075705', 'brand' => 'IND',
      'street' => '12010 State Hwy 31 E', 'city' => 'Tyler', 'state' => 'TX',
      'postal_code' => '75705', 'phone' => '9035967608',
      'latitude' => 32.3665, 'longitude' => -95.1299, 'inventory_count' => 9,
      'url' => 'https://www.claytonhomes.com/locations/mobile-home-masters-inc' }
  end
  let(:academy) do
    mhm.merge('slug' => 'academy-homes', 'name' => 'Academy Homes', 'postal_code' => '75701',
              'url' => 'https://www.claytonhomes.com/locations/academy-homes')
  end

  before do
    allow(Catalog::ClaytonHomeCenterDirectory).to receive(:all).and_return([mhm, academy])
    allow(Catalog::ClaytonHomeCenterDirectory).to receive(:find_by_slug) { |s| [mhm, academy].find { |e| e['slug'] == s } }
    allow(Catalog::ClaytonHomeCenterDirectory).to receive(:fetched_at).and_return(Time.current)
    allow(Catalog::ClaytonHomeCenterDirectory).to receive(:stale?).and_return(false)
  end

  describe 'GET clayton_home_centers' do
    it 'rejects non-platform-admins' do
      get '/api/admin/catalog_sources/clayton_home_centers', headers: regular_headers
      expect(response).to have_http_status(:forbidden)
    end

    it 'searches the directory by city' do
      get '/api/admin/catalog_sources/clayton_home_centers', params: { q: 'tyler' }, headers: admin_headers
      expect(response).to have_http_status(:ok)
      names = JSON.parse(response.body)['items'].map { |i| i['name'] }
      expect(names).to include('Mobile Home Masters Inc', 'Academy Homes')
    end

    it 'searches by dealer name' do
      get '/api/admin/catalog_sources/clayton_home_centers', params: { q: 'masters' }, headers: admin_headers
      items = JSON.parse(response.body)['items']
      expect(items.map { |i| i['slug'] }).to eq(['mobile-home-masters-inc'])
    end

    context 'when the directory cache is cold' do
      before do
        allow(Catalog::ClaytonHomeCenterDirectory).to receive(:stale?).and_return(true)
        allow(Catalog::ClaytonHomeCenterDirectory).to receive(:all).and_return([])
        Rails.cache.delete('clayton_directory_refresh_enqueued')
      end

      it 'never crawls inline — it enqueues a refresh and tells the UI to poll' do
        expect { get '/api/admin/catalog_sources/clayton_home_centers', headers: admin_headers }
          .to have_enqueued_job(ClaytonDirectoryRefreshJob)
        expect(response).to have_http_status(:accepted)
        expect(JSON.parse(response.body)['refreshing']).to be(true)
      end

      # The test env runs :null_store, so the debounce lock can't be observed
      # without a real store standing in for it.
      it 'debounces so typeahead keystrokes do not pile up crawls' do
        allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)

        get '/api/admin/catalog_sources/clayton_home_centers', headers: admin_headers
        expect { get '/api/admin/catalog_sources/clayton_home_centers', headers: admin_headers }
          .not_to have_enqueued_job(ClaytonDirectoryRefreshJob)
      end
    end

    it 'flags home centers already registered so the admin cannot double-add' do
      source = create(:catalog_source, adapter_type: 'clayton_retail_home_center', base_url: mhm['url'])

      get '/api/admin/catalog_sources/clayton_home_centers', params: { q: 'tyler' }, headers: admin_headers
      items = JSON.parse(response.body)['items'].index_by { |i| i['slug'] }
      expect(items['mobile-home-masters-inc']['existing_source_id']).to eq(source.id)
      expect(items['academy-homes']['existing_source_id']).to be_nil
    end
  end

  describe 'POST create with home_center_slug' do
    subject(:create_source) do
      post '/api/admin/catalog_sources',
           params: { home_center_slug: 'mobile-home-masters-inc' }.to_json,
           headers: admin_headers
    end

    it 'derives name, base_url and adapter type from the directory entry' do
      create_source
      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body['name']).to eq('Clayton — Mobile Home Masters Inc (Tyler, TX)')
      expect(body['adapterType']).to eq('clayton_retail_home_center')
      expect(body['baseUrl']).to eq(mhm['url'])
    end

    it 'marks series/description untracked so the source can reach a clean run' do
      create_source
      source = CatalogSource.find(JSON.parse(response.body)['id'])
      expect(source.untracked_fields).to contain_exactly('series', 'description')
    end

    it 'stores the home center identity for display' do
      create_source
      source = CatalogSource.find(JSON.parse(response.body)['id'])
      expect(source.config['home_center']).to include(
        'dealer_number' => '075705', 'brand' => 'IND', 'city' => 'Tyler', 'state' => 'TX'
      )
    end

    it 'defaults starting price ON' do
      create_source
      source = CatalogSource.find(JSON.parse(response.body)['id'])
      expect(source.config['include_starting_price']).to be(true)
    end

    it 'honours an explicit starting-price opt-out' do
      post '/api/admin/catalog_sources',
           params: { home_center_slug: 'mobile-home-masters-inc', include_starting_price: false }.to_json,
           headers: admin_headers
      source = CatalogSource.find(JSON.parse(response.body)['id'])
      expect(source.config['include_starting_price']).to be(false)
    end

    it 'creates the source disabled, pending a passing Test' do
      create_source
      source = CatalogSource.find(JSON.parse(response.body)['id'])
      expect(source.enabled).to be(false)
      expect(source.selectable_for_dealers?).to be(false)
    end

    it 'rejects an unknown slug' do
      post '/api/admin/catalog_sources',
           params: { home_center_slug: 'not-a-real-dealer' }.to_json, headers: admin_headers
      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['error']).to match(/Unknown Clayton home center/)
    end

    it 'refuses a duplicate and points at the existing source' do
      existing = create(:catalog_source, adapter_type: 'clayton_retail_home_center', base_url: mhm['url'])
      create_source
      expect(response).to have_http_status(:conflict)
      expect(JSON.parse(response.body)['sourceId']).to eq(existing.id)
    end

    it 'still accepts a conventional payload for non-Clayton adapters' do
      post '/api/admin/catalog_sources',
           params: { catalog_source: { name: 'Kabco', adapter_type: 'avada_sitemap',
                                       base_url: 'https://kabco.example' } }.to_json,
           headers: admin_headers
      expect(response).to have_http_status(:created)
      expect(JSON.parse(response.body)['adapterType']).to eq('avada_sitemap')
    end
  end

  describe 'POST refresh_clayton_directory' do
    it 'enqueues the crawl rather than running it in the request' do
      expect { post '/api/admin/catalog_sources/refresh_clayton_directory', headers: admin_headers }
        .to have_enqueued_job(ClaytonDirectoryRefreshJob)
      expect(response).to have_http_status(:accepted)
    end

    it 'rejects non-platform-admins' do
      post '/api/admin/catalog_sources/refresh_clayton_directory', headers: regular_headers
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'GET adapter_options' do
    it 'advertises the picker and the starting-price toggle' do
      get '/api/admin/catalog_sources/adapter_options', headers: admin_headers
      opts = JSON.parse(response.body)['clayton_retail_home_center']
      expect(opts['picker_endpoint']).to eq('/api/admin/catalog_sources/clayton_home_centers')
      expect(opts['options'].map { |o| o['key'] }).to include('include_starting_price')
    end

    it 'warns that Epic overlaps a dealer catalog' do
      get '/api/admin/catalog_sources/adapter_options', headers: admin_headers
      expect(JSON.parse(response.body).dig('clayton_epic_region', 'advisory')).to match(/ingests them twice/)
    end
  end
end
