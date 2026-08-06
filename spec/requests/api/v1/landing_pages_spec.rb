# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::LandingPages', type: :request do
  let(:company) { Company.create!(name: "LPReq-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:token) { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }

  let(:site) { Marketing::MarketingSiteProvisioner.call(company: company) }
  let(:page) do
    site.website_pages.create!(
      title: 'Spring Sale', path: '/spring-sale', page_kind: 'landing',
      blocks: [{ 'id' => 'b1', 'type' => 'hero', 'order' => 0, 'content' => { 'title' => 'Spring Sale' } }]
    )
  end

  def json = JSON.parse(response.body)

  describe 'POST /api/v1/landing_pages' do
    it 'creates a landing page, provisioning the marketing container on first use' do
      expect(company.websites.marketing_containers).to be_empty

      post '/api/v1/landing_pages',
           params: { title: 'Autumn Offer', layout_id: 'lp-offer-focus' }.to_json,
           headers: headers

      expect(response).to have_http_status(:created)
      expect(json['page_kind']).to eq('landing')
      expect(json['layout_id']).to eq('lp-offer-focus')
      expect(company.websites.marketing_containers.count).to eq(1)
    end

    it 'defaults a new landing page to noindex and unpublished' do
      post '/api/v1/landing_pages', params: { title: 'Autumn Offer' }.to_json, headers: headers

      expect(json['robots']).to eq('noindex, nofollow')
      expect(json['published']).to be(false)
    end

    it 'reuses the container on a second create' do
      2.times do |i|
        post '/api/v1/landing_pages', params: { title: "Offer #{i}" }.to_json, headers: headers
      end
      expect(company.websites.marketing_containers.count).to eq(1)
    end
  end

  describe 'GET /api/v1/landing_pages' do
    it 'lists landing pages with stats' do
      page
      get '/api/v1/landing_pages', headers: headers

      expect(response).to have_http_status(:ok)
      expect(json['items'].map { |i| i['title'] }).to include('Spring Sale')
      expect(json['meta']['stats']).to include('total' => 1, 'draft' => 1, 'published' => 0)
    end

    # Ordinary site pages are a different surface and must not appear here.
    it 'excludes ordinary site pages' do
      site.website_pages.create!(title: 'About Us', path: '/about')
      get '/api/v1/landing_pages', headers: headers

      expect(json['items'].map { |i| i['title'] }).not_to include('About Us')
    end

    it 'filters by campaign' do
      campaign = Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'C',
                                  campaign_type: 'blast', from_identity_type: 'User',
                                  from_identity_id: user.id, throttle_per_day: 100)
      page.update!(campaign_id: campaign.id)
      site.website_pages.create!(title: 'Unlinked', path: '/unlinked', page_kind: 'landing')

      get "/api/v1/landing_pages?campaign_id=#{campaign.id}", headers: headers
      expect(json['items'].map { |i| i['title'] }).to eq(['Spring Sale'])
    end
  end

  describe 'publish / unpublish' do
    it 'publishes and unpublishes at the page level' do
      post "/api/v1/landing_pages/#{page.id}/publish", headers: headers
      expect(json['published']).to be(true)
      expect(json['public_url']).to end_with('/spring-sale')

      post "/api/v1/landing_pages/#{page.id}/unpublish", headers: headers
      expect(json['published']).to be(false)
    end

    # The container is always site-published; page state is the real gate.
    it 'leaves the container published throughout' do
      post "/api/v1/landing_pages/#{page.id}/unpublish", headers: headers
      expect(site.reload.status).to eq('published')
    end
  end

  describe 'POST /:id/duplicate' do
    it 'returns a fresh unpublished copy' do
      page.publish!

      post "/api/v1/landing_pages/#{page.id}/duplicate", headers: headers

      expect(response).to have_http_status(:created)
      expect(json['title']).to eq('(Copy) Spring Sale')
      expect(json['path']).to eq('/spring-sale-copy')
      expect(json['published']).to be(false)
      expect(json['id']).not_to eq(page.id)
    end

    it 'accepts a title override' do
      post "/api/v1/landing_pages/#{page.id}/duplicate",
           params: { title: 'Summer Sale' }.to_json, headers: headers

      expect(json['title']).to eq('Summer Sale')
    end
  end

  describe 'POST /:id/clone_to_locations' do
    let!(:boulder) { company.locations.create!(name: 'Boulder Showroom') }
    let!(:pueblo)  { company.locations.create!(name: 'Pueblo Showroom') }

    it 'creates one copy per location' do
      post "/api/v1/landing_pages/#{page.id}/clone_to_locations",
           params: { location_ids: [boulder.id, pueblo.id] }.to_json, headers: headers

      expect(response).to have_http_status(:created)
      expect(json['cloned_count']).to eq(2)
      expect(json['failures']).to be_empty
      expect(json['items'].map { |i| i['title'] }).to contain_exactly(
        'Spring Sale — Boulder Showroom', 'Spring Sale — Pueblo Showroom'
      )
    end

    it 'rejects an empty location list' do
      post "/api/v1/landing_pages/#{page.id}/clone_to_locations",
           params: { location_ids: [] }.to_json, headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json['error']).to match(/at least one location/i)
    end

    # Locations are resolved through the company, so an id from elsewhere
    # simply is not found.
    it 'ignores locations belonging to another company' do
      other = Company.create!(name: "Other-#{SecureRandom.hex(4)}")
      foreign = other.locations.create!(name: 'Not Ours')

      post "/api/v1/landing_pages/#{page.id}/clone_to_locations",
           params: { location_ids: [foreign.id] }.to_json, headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe 'tenant isolation' do
    it 'cannot read another company landing page' do
      other = Company.create!(name: "Other-#{SecureRandom.hex(4)}")
      other_site = Marketing::MarketingSiteProvisioner.call(company: other)
      foreign = other_site.website_pages.create!(title: 'Theirs', path: '/theirs', page_kind: 'landing')

      get "/api/v1/landing_pages/#{foreign.id}", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it 'cannot duplicate another company landing page' do
      other = Company.create!(name: "Other-#{SecureRandom.hex(4)}")
      other_site = Marketing::MarketingSiteProvisioner.call(company: other)
      foreign = other_site.website_pages.create!(title: 'Theirs', path: '/theirs', page_kind: 'landing')

      post "/api/v1/landing_pages/#{foreign.id}/duplicate", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'DELETE /:id' do
    it 'soft-deletes and takes the page offline' do
      page.publish!
      delete "/api/v1/landing_pages/#{page.id}", headers: headers

      expect(response).to have_http_status(:no_content)
      page.reload
      expect(page.is_deleted).to be(true)
      expect(page.published?).to be(false)
    end
  end

  describe 'GET /:id/analytics' do
    it 'returns the funnel, engagement, video, sources and timeseries' do
      PageVisit.create!(company_id: company.id, website_page_id: page.id,
                        visitor_token: 'v1', session_token: 's1',
                        max_scroll_depth: 100, converted: true,
                        first_seen_at: 1.hour.ago, last_seen_at: 1.hour.ago)

      get "/api/v1/landing_pages/#{page.id}/analytics", headers: headers

      expect(response).to have_http_status(:ok)
      expect(json['funnel']).to include('visits' => 1, 'conversions' => 1)
      expect(json).to have_key('engagement')
      expect(json).to have_key('video')
      expect(json).to have_key('sources')
      expect(json).to have_key('timeseries')
    end

    it 'returns zeroes for a page with no traffic' do
      get "/api/v1/landing_pages/#{page.id}/analytics", headers: headers

      expect(json['funnel']['visits']).to eq(0)
      expect(json['funnel']['conversion_rate']).to eq(0.0)
    end
  end

  describe 'GET /:id/visitors' do
    let(:source) { Source.find_or_create_by!(name: 'Web') { |s| s.source_type = 'web' } }
    let(:lead) do
      Lead.create!(company: company, source: source, first_name: 'Dana', last_name: 'Reed',
                   status: 'new', email: "d-#{SecureRandom.hex(4)}@example.com")
    end

    # An anonymous row has nothing a salesperson can act on.
    it 'lists identified visitors only' do
      identified = PageVisit.create!(company_id: company.id, website_page_id: page.id,
                                     visitor_token: 'v1', session_token: 's1',
                                     first_seen_at: 1.hour.ago, last_seen_at: 1.hour.ago)
      identified.identify!(lead)
      PageVisit.create!(company_id: company.id, website_page_id: page.id,
                        visitor_token: 'v2', session_token: 's2',
                        first_seen_at: 1.hour.ago, last_seen_at: 1.hour.ago)

      get "/api/v1/landing_pages/#{page.id}/visitors", headers: headers

      expect(json['items'].size).to eq(1)
      expect(json['items'].first['entity_type']).to eq('Lead')
      expect(json['items'].first['entity_id']).to eq(lead.id)
    end
  end

  describe 'the marketing container stays hidden' do
    it 'does not appear in the websites list' do
      page # provisions the container
      get '/api/v1/websites', headers: headers

      names = JSON.parse(response.body)['items'].map { |w| w['name'] }
      expect(names).not_to include(site.name)
    end

    it 'is not addressable through the websites API' do
      get "/api/v1/websites/#{site.id}", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end
end
