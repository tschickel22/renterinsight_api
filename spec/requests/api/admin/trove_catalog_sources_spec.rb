# frozen_string_literal: true

require 'rails_helper'

# Two production regressions, both of which made a perfectly healthy Trove
# source unusable from the admin UI:
#
#   1. A source created through the form had no `untracked_fields`, so a 93/93
#      run with every field at 100% except description still landed "partial"
#      and degraded — and a degraded source can never be enabled.
#   2. Saving the form round-tripped config without `snapshot_key`, silently
#      un-binding the snapshot and sending the source back to live crawling,
#      which Trove blocks. The next run discovered 0 and failed.
RSpec.describe 'Api::Admin::CatalogSources Trove config', type: :request do
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
    { name: 'Legacy Homes', adapter_type: 'trove_catalog',
      base_url: 'https://trove.legacyhousing.com', schedule: 'manual' }
  end

  describe 'POST create' do
    it 'excuses description automatically, so a clean run is reachable' do
      post '/api/admin/catalog_sources',
           params: { catalog_source: base_attrs }.to_json, headers: admin_headers

      expect(response).to have_http_status(:created)
      config = JSON.parse(response.body)['config']
      expect(config['untracked_fields']).to eq(['description'])
    end

    it 'keeps a snapshot chosen in the form' do
      post '/api/admin/catalog_sources',
           params: { catalog_source: base_attrs.merge(config: { snapshot_key: 'legacy_housing' }) }.to_json,
           headers: admin_headers

      config = JSON.parse(response.body)['config']
      expect(config['snapshot_key']).to eq('legacy_housing')
      expect(config['untracked_fields']).to eq(['description'])
    end

    it 'leaves other adapters alone' do
      post '/api/admin/catalog_sources',
           params: { catalog_source: base_attrs.merge(adapter_type: 'avada_sitemap') }.to_json,
           headers: admin_headers

      expect(JSON.parse(response.body)['config']['untracked_fields']).to be_nil
    end
  end

  describe 'PATCH update' do
    let!(:source) do
      CatalogSource.create!(base_attrs.merge(
                              config: { 'snapshot_key' => 'legacy_housing',
                                        'untracked_fields' => ['description'] }
                            ))
    end

    # The exact production failure: the form posts config back without
    # snapshot_key, the source silently goes live, and the next run fails.
    it 'does not un-bind the snapshot when config omits it' do
      patch "/api/admin/catalog_sources/#{source.id}",
            params: { catalog_source: { config: { crawl_delay: 5 } } }.to_json,
            headers: admin_headers

      expect(response).to have_http_status(:ok)
      expect(source.reload.config['snapshot_key']).to eq('legacy_housing')
      expect(source.config['untracked_fields']).to eq(['description'])
    end

    # Going live has to stay possible — that is the whole point of the flag.
    it 'clears the snapshot when explicitly sent as null' do
      patch "/api/admin/catalog_sources/#{source.id}",
            params: { catalog_source: { config: { snapshot_key: nil } } }.to_json,
            headers: admin_headers

      expect(source.reload.config['snapshot_key']).to be_nil
    end

    it 'restores untracked_fields if a form drops them' do
      source.update!(config: source.config.except('untracked_fields'))

      patch "/api/admin/catalog_sources/#{source.id}",
            params: { catalog_source: { config: {} } }.to_json, headers: admin_headers

      expect(source.reload.config['untracked_fields']).to eq(['description'])
    end
  end

  # The reason any of this matters: degraded sources cannot be enabled, so a
  # missing untracked_fields entry is the difference between a usable source
  # and a dead one.
  describe 'degradation' do
    let(:rates) do
      { 'model_name' => 1.0, 'model_id' => 1.0, 'series' => 1.0, 'property_type' => 1.0,
        'bedrooms' => 1.0, 'bathrooms' => 1.0, 'dimensions' => 1.0, 'square_feet' => 1.0,
        'images' => 1.0, 'description' => 0.0 }
    end

    it 'counts a 0% description as degraded without the excuse' do
      expect(Catalog::ExtractionStats.degraded?(rates, 0.7, untracked: [])).to be(true)
    end

    it 'is clean once description is excused' do
      expect(Catalog::ExtractionStats.degraded?(rates, 0.7, untracked: ['description'])).to be(false)
    end
  end

  # Until Trove allowlists us, refreshing inventory means re-capturing in a
  # browser. Requiring a production shell for that makes "Legacy added models"
  # an engineering task instead of an admin one.
  describe 'POST upload_snapshot' do
    let(:home) do
      { 'short_id' => 'legacy-housing-classic-collection-c-1660-21fka',
        'name' => 'Classic C-1660-21FKA', 'supplier_sku' => 'C-1660-21FKA',
        'price' => { 'retail_micros' => 5_590_000 },
        'details' => { 'width_inches' => 192, 'length_inches' => 720, 'square_feet' => 880,
                       'bedrooms' => 2, 'bathrooms' => 1, 'sections' => 1 },
        'images' => [{ 'image_url' => 'https://trove.b-cdn.net/images/a.png',
                       'image_tags' => ['floor_plan'] }] }
    end
    let(:payload) do
      { 'schema' => Catalog::TroveSnapshot::SCHEMA,
        'base_url' => 'https://trove.legacyhousing.com',
        'supplier_name' => 'Legacy Housing',
        'captured_at' => '2026-08-01T00:00:00Z',
        'homes' => [home] }
    end

    it 'stores the capture and derives the key from the host' do
      post '/api/admin/catalog_sources/upload_snapshot',
           params: { snapshot: payload }.to_json, headers: admin_headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['key']).to eq('legacy_housing')
      expect(body['home_count']).to eq(1)
      expect(body['image_count']).to eq(1)
      expect(body['replaced']).to be(false)
      expect(Catalog::TroveSnapshot.read('legacy_housing')['homes'].size).to eq(1)
    end

    # The point of re-uploading: show whether the capture actually moved.
    it 'reports what it replaced' do
      Catalog::TroveSnapshot.write('legacy_housing', payload.merge('homes' => [home, home.merge('short_id' => 'x')]))

      post '/api/admin/catalog_sources/upload_snapshot',
           params: { snapshot: payload, key: 'legacy_housing' }.to_json, headers: admin_headers

      body = JSON.parse(response.body)
      expect(body['replaced']).to be(true)
      expect(body['previous_home_count']).to eq(2)
      expect(body['home_count']).to eq(1)
    end

    it 'rejects a payload from a different tool' do
      post '/api/admin/catalog_sources/upload_snapshot',
           params: { snapshot: payload.merge('schema' => 'something/else') }.to_json,
           headers: admin_headers

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'rejects an empty capture rather than wiping a good one' do
      Catalog::TroveSnapshot.write('legacy_housing', payload)

      post '/api/admin/catalog_sources/upload_snapshot',
           params: { snapshot: payload.merge('homes' => []) }.to_json, headers: admin_headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(Catalog::TroveSnapshot.read('legacy_housing')['homes'].size).to eq(1)
    end

    it 'is platform-admin only' do
      user = user_with('sales')
      token = JsonWebToken.encode(user_id: user.id, company_id: company.id)
      post '/api/admin/catalog_sources/upload_snapshot',
           params: { snapshot: payload }.to_json,
           headers: { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' }

      expect(response.status).to be_in([401, 403])
    end
  end
end
