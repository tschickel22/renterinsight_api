# frozen_string_literal: true

require 'rails_helper'

# Importing a profile that was scanned somewhere else.
#
# Some prospect sites refuse the server outright: a bot check that never clears
# in two minutes from Render clears in a tenth of a second on a laptop, same
# browser build, because the address is what is being refused. So the scan runs
# where it works and only the finished profile is sent up. Nothing expensive
# happens in this endpoint — no crawl, no browser, no model call.
RSpec.describe 'POST /api/v1/site_content_profiles/import', type: :request do
  let(:company) { create(:company, use_rbac_system: false) }

  def user_with(role)
    User.create!(email: "import-#{SecureRandom.hex(4)}@example.com", password: 'Password123!',
                 company: company, first_name: 'Tom', last_name: 'Admin', role: role)
  end

  def headers_for(user)
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}",
      'CONTENT_TYPE' => 'application/json' }
  end

  let(:payload) do
    {
      source_url: 'https://thehomeplus.com',
      display_name: 'Home + Design Studio',
      profile: {
        'brand' => { 'name' => 'Home+ Design Studio', 'logo_url' => 'https://cdn.example.com/mark.png' },
        'copy' => { 'about' => [{ 'body' => 'Family owned since 1998.' }] }
      },
      report: { 'page_count' => 10, 'pages_rendered' => 10 },
      seo_report: { 'score' => 62, 'pages_checked' => 10 },
      preview_template_ids: %w[manufactured-home-elite coastal-living]
    }
  end

  it 'creates a shareable demo from a profile scanned elsewhere' do
    post '/api/v1/site_content_profiles/import', params: payload.to_json,
                                                 headers: headers_for(user_with('platform_admin'))

    expect(response).to have_http_status(:created)
    body = JSON.parse(response.body)
    expect(body['status']).to eq('ready')
    expect(body['preview_token']).to be_present
    expect(body['profile']['brand']['name']).to eq('Home+ Design Studio')
    expect(body['preview_template_ids']).to eq(%w[manufactured-home-elite coastal-living])
  end

  it 'is immediately readable on the public preview endpoint' do
    post '/api/v1/site_content_profiles/import', params: payload.to_json,
                                                 headers: headers_for(user_with('platform_admin'))
    token = JSON.parse(response.body)['preview_token']

    get "/api/v1/site_content_profiles/by_token/#{token}"

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body).dig('profile', 'brand', 'name')).to eq('Home+ Design Studio')
  end

  # Where it was read matters later, when a demo looks stale and nobody
  # remembers it came from a laptop.
  # Which client's Demo Sites list it landed in. A platform-level key defaults
  # to its owner's tenant, so a demo built for a client can end up somewhere
  # that client cannot see — and "it worked" did not say where it went.
  it 'says which tenant owns the demo it just created' do
    post '/api/v1/site_content_profiles/import', params: payload.to_json,
                                                 headers: headers_for(user_with('platform_admin'))

    body = JSON.parse(response.body)
    expect(body['company_id']).to eq(company.id)
    expect(body['company_name']).to eq(company.name)
  end

  it 'records that it was imported' do
    post '/api/v1/site_content_profiles/import', params: payload.to_json,
                                                 headers: headers_for(user_with('platform_admin'))

    expect(SiteContentProfile.last.report['imported_at']).to be_present
    expect(SiteContentProfile.last.report['page_count']).to eq(10)
  end

  it 'keeps the SEO review that came with it' do
    post '/api/v1/site_content_profiles/import', params: payload.to_json,
                                                 headers: headers_for(user_with('platform_admin'))

    expect(SiteContentProfile.last.seo_report['score']).to eq(62)
  end

  it 'refuses a profile with no content' do
    post '/api/v1/site_content_profiles/import', params: payload.except(:profile).to_json,
                                                 headers: headers_for(user_with('platform_admin'))

    expect(response).to have_http_status(:unprocessable_entity)
  end

  # This writes a demo that anyone with the link can read, so it is platform
  # admin only like every other write on this controller.
  it 'refuses an ordinary user' do
    post '/api/v1/site_content_profiles/import', params: payload.to_json,
                                                 headers: headers_for(user_with('user'))

    expect(response).to have_http_status(:forbidden)
  end

  # An API key rather than a browser login, because this is called from a rake
  # task on a schedule set by prospects: a JWT expires after 7 days and the
  # workflow would break every week for no visible reason.
  describe 'authenticating with an API key' do
    # Resources are seeded by migration in a real database; the test one starts
    # empty, and ApiKey validates its permissions against them.
    before do
      Resource.find_or_create_by!(key: 'websites') { |r| r.name = 'Websites' }
      Resource.find_or_create_by!(key: 'leads') { |r| r.name = 'Leads' }
    end

    def key_with(permissions:, company: nil)
      ApiKey.create!(name: "push-#{SecureRandom.hex(3)}", company: company,
                     created_by_user: user_with('platform_admin'),
                     status: 'active', permissions: permissions, rate_limit: 1000)
    end

    def post_with(key, extra = {})
      post '/api/v1/site_content_profiles/import', params: payload.to_json,
                                                   headers: { 'Authorization' => "Bearer #{key.key}",
                                                              'CONTENT_TYPE' => 'application/json' }.merge(extra)
    end

    it 'accepts a company-scoped key carrying websites:write' do
      post_with(key_with(permissions: { 'websites' => ['write'] }, company: company))

      expect(response).to have_http_status(:created)
      expect(SiteContentProfile.last.company_id).to eq(company.id)
    end

    it 'accepts a platform-level key when it says which tenant' do
      post_with(key_with(permissions: { 'websites' => ['write'] }), 'X-Company-ID' => company.id.to_s)

      expect(response).to have_http_status(:created)
    end

    # Falling back to the admin's own company rather than demanding a tenant id
    # they would have to go and look up — after a six minute scan has run.
    it 'files a platform-level key under whoever minted it when no tenant is named' do
      post_with(key_with(permissions: { 'websites' => ['write'] }))

      expect(response).to have_http_status(:created)
      expect(SiteContentProfile.last.company_id).to eq(company.id)
    end

    it 'lets an explicit tenant win over the key own company' do
      other = create(:company)
      post_with(key_with(permissions: { 'websites' => ['write'] }, company: company),
                'X-Company-ID' => other.id.to_s)

      expect(SiteContentProfile.last.company_id).to eq(other.id)
    end

    it 'refuses a key that cannot write websites' do
      post_with(key_with(permissions: { 'leads' => ['read'] }, company: company))

      expect(response).to have_http_status(:forbidden)
    end

    it 'refuses a revoked key' do
      key = key_with(permissions: { 'websites' => ['write'] }, company: company)
      key.update!(status: 'revoked')

      post_with(key)

      expect(response).to have_http_status(:unauthorized)
    end

    it 'refuses a key that does not exist' do
      post '/api/v1/site_content_profiles/import', params: payload.to_json,
                                                   headers: { 'Authorization' => 'Bearer ri_live_nope',
                                                              'CONTENT_TYPE' => 'application/json' }

      expect(response).to have_http_status(:unauthorized)
    end
  end

  # Adjusting a demo after it exists, with the same credential that created it.
  # The link is already in a prospect's inbox, so changing which designs it
  # offers must not mean rescanning and reissuing it.
  describe 'configuring a demo with an API key' do
    before do
      Resource.find_or_create_by!(key: 'websites') { |r| r.name = 'Websites' }
    end

    let(:key) do
      ApiKey.create!(name: "cfg-#{SecureRandom.hex(3)}", company: company,
                     created_by_user: user_with('platform_admin'), status: 'active',
                     permissions: { 'websites' => ['write'] }, rate_limit: 1000)
    end

    let(:demo) do
      SiteContentProfile.create!(company: company, source_url: 'https://thehomeplus.com',
                                 status: 'ready', preview_template_ids: [], profile: { 'brand' => {} })
    end

    def key_headers
      { 'Authorization' => "Bearer #{key.key}", 'CONTENT_TYPE' => 'application/json' }
    end

    it 'narrows the designs a demo offers' do
      patch "/api/v1/site_content_profiles/#{demo.id}",
            params: { preview_template_ids: %w[manufactured-home-elite coastal-living] }.to_json,
            headers: key_headers

      expect(response).to have_http_status(:ok)
      expect(demo.reload.preview_template_ids).to eq(%w[manufactured-home-elite coastal-living])
    end

    it 'points it at a different inventory lot' do
      lot = create(:company)

      patch "/api/v1/site_content_profiles/#{demo.id}",
            params: { inventory_company_id: lot.id }.to_json, headers: key_headers

      expect(demo.reload.inventory_company_id).to eq(lot.id)
    end

    it 'leaves the shareable link alone' do
      before_token = demo.preview_token

      patch "/api/v1/site_content_profiles/#{demo.id}",
            params: { preview_template_ids: ['coastal-living'] }.to_json, headers: key_headers

      expect(demo.reload.preview_token).to eq(before_token)
    end

    it 'lists demos so a task can find one by its link' do
      demo

      get '/api/v1/site_content_profiles', headers: key_headers

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['items'].map { |i| i['preview_token'] }).to include(demo.preview_token)
    end

    it 'refuses a key that cannot write websites' do
      read_only = ApiKey.create!(name: "ro-#{SecureRandom.hex(3)}", company: company,
                                 created_by_user: user_with('platform_admin'), status: 'active',
                                 permissions: { 'websites' => ['read'] }, rate_limit: 1000)

      patch "/api/v1/site_content_profiles/#{demo.id}",
            params: { preview_template_ids: ['coastal-living'] }.to_json,
            headers: { 'Authorization' => "Bearer #{read_only.key}", 'CONTENT_TYPE' => 'application/json' }

      expect(response).to have_http_status(:forbidden)
    end

    # Another company's demo is not reachable with this key, key or no key.
    it 'cannot touch a demo belonging to someone else' do
      other = SiteContentProfile.create!(company: create(:company), source_url: 'https://x.com',
                                         status: 'ready', profile: {})

      patch "/api/v1/site_content_profiles/#{other.id}",
            params: { preview_template_ids: ['coastal-living'] }.to_json, headers: key_headers

      expect(response).to have_http_status(:not_found)
    end
  end

  it 'refuses an unauthenticated request' do
    post '/api/v1/site_content_profiles/import', params: payload.to_json,
                                                 headers: { 'CONTENT_TYPE' => 'application/json' }

    expect(response).to have_http_status(:unauthorized)
  end
end
