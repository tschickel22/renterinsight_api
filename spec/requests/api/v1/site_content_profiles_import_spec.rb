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

  it 'refuses an unauthenticated request' do
    post '/api/v1/site_content_profiles/import', params: payload.to_json,
                                                 headers: { 'CONTENT_TYPE' => 'application/json' }

    expect(response).to have_http_status(:unauthorized)
  end
end
