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

  describe 'GET adapter_options' do
    it 'offers the adapter to the create dialog' do
      get '/api/admin/catalog_sources/adapter_options', headers: admin_headers

      options = JSON.parse(response.body)['adventure_homes']
      expect(options['untracked_fields']).to eq(['description'])
      expect(options['base_url_template']).to eq('https://adventurehomes.net')
    end
  end
end
