# frozen_string_literal: true

require 'rails_helper'

# The same regression Trove hit, guarded for Adventure Homes: a source created
# through the admin dialog carried no `untracked_fields`, so a run that parsed
# all 130 homes with every field at 100% except `description` — which Adventure
# publishes nowhere on the site — still landed degraded, and a degraded source
# can never be enabled.
RSpec.describe 'Api::Admin::CatalogSources Adventure Homes config', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }

  def user_with(role)
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com",
                 first_name: 'Tom', last_name: 'Schickel',
                 password: 'Pass1234!', company_id: company.id, role: role)
  end

  let(:admin_headers) do
    user = user_with('platform_admin')
    token = JsonWebToken.encode(user_id: user.id, company_id: company.id)
    { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' }
  end

  let(:base_attrs) do
    { name: 'Adventure Homes', adapter_type: 'adventure_homes',
      base_url: 'https://adventurehomes.net', schedule: 'daily' }
  end

  describe 'POST create' do
    it 'excuses description automatically, so a clean run is reachable' do
      post '/api/admin/catalog_sources',
           params: { catalog_source: base_attrs }.to_json, headers: admin_headers

      expect(response).to have_http_status(:created)
      expect(JSON.parse(response.body)['config']['untracked_fields']).to eq(['description'])
    end

    it 'keeps a crawl delay chosen in the form' do
      post '/api/admin/catalog_sources',
           params: { catalog_source: base_attrs.merge(config: { crawl_delay: 8 }) }.to_json,
           headers: admin_headers

      config = JSON.parse(response.body)['config']
      expect(config['crawl_delay']).to eq(8)
      expect(config['untracked_fields']).to eq(['description'])
    end
  end

  describe 'POST upload_snapshot' do
    let(:source) do
      CatalogSource.create!(name: 'Adventure Homes', adapter_type: 'adventure_homes',
                            base_url: 'https://adventurehomes.net', schedule: 'daily')
    end

    let(:payload) do
      home = Catalog::NormalizedHome.new(
        source_key: '0663ls', model_name: '0663LS', bedrooms: 3, bathrooms: '2',
        square_feet: 1560, images: [{ 'source_url' => 'https://adventurehomes.net/a.jpg' }]
      )
      Catalog::HomesSnapshot.build(source: source, homes: [home])
    end

    it 'routes a parsed-homes capture to its own store, not Trove\'s' do
      post '/api/admin/catalog_sources/upload_snapshot',
           params: { snapshot: payload, key: 'adventure_homes' }.to_json, headers: admin_headers

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to include('key' => 'adventure_homes', 'home_count' => 1)
      expect(Catalog::HomesSnapshot.read('adventure_homes')['homes'].size).to eq(1)
      expect(Catalog::TroveSnapshot.read('adventure_homes')).to be_nil
    end

    # Otherwise the upload succeeds and the source keeps crawling live, which
    # against a blocked host looks like the snapshot did nothing.
    it 'binds the snapshot to the source when given one' do
      post '/api/admin/catalog_sources/upload_snapshot',
           params: { snapshot: payload, key: 'adventure_homes', source_id: source.id }.to_json,
           headers: admin_headers

      expect(JSON.parse(response.body)['bound_source_id']).to eq(source.id)
      expect(source.reload.config['snapshot_key']).to eq('adventure_homes')
    end

    it 'leaves the rest of the source config alone when binding' do
      source.update!(config: { 'crawl_delay' => 5, 'untracked_fields' => ['description'] })

      post '/api/admin/catalog_sources/upload_snapshot',
           params: { snapshot: payload, key: 'adventure_homes', source_id: source.id }.to_json,
           headers: admin_headers

      expect(source.reload.config)
        .to include('crawl_delay' => 5, 'untracked_fields' => ['description'],
                    'snapshot_key' => 'adventure_homes')
    end

    it 'reports what a re-capture replaced, so a refresh is visible' do
      post '/api/admin/catalog_sources/upload_snapshot',
           params: { snapshot: payload, key: 'adventure_homes' }.to_json, headers: admin_headers
      post '/api/admin/catalog_sources/upload_snapshot',
           params: { snapshot: payload, key: 'adventure_homes' }.to_json, headers: admin_headers

      body = JSON.parse(response.body)
      expect(body['replaced']).to be(true)
      expect(body['previous_home_count']).to eq(1)
    end

    it 'rejects a payload whose schema matches neither store' do
      post '/api/admin/catalog_sources/upload_snapshot',
           params: { snapshot: payload.merge('schema' => 'something/v9'), key: 'x' }.to_json,
           headers: admin_headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['error']).to match(/unexpected snapshot schema/)
    end
  end

  describe 'GET adapter_options' do
    it 'offers the adapter to the create dialog' do
      get '/api/admin/catalog_sources/adapter_options', headers: admin_headers

      options = JSON.parse(response.body)['adventure_homes']
      expect(options['untracked_fields']).to eq(['description'])
      expect(options['base_url_template']).to eq('https://adventurehomes.net')
    end
  end
end
