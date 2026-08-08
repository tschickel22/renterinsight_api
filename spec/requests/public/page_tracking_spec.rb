# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Public::PageTracking', type: :request do
  let(:company) { Company.create!(name: "Beacon-#{SecureRandom.hex(4)}") }
  let(:site) { Marketing::MarketingSiteProvisioner.call(company: company) }
  let(:page) { site.website_pages.create!(title: 'Spring Sale', path: '/spring-sale', page_kind: 'landing') }

  let(:payload) do
    { visitor_token: 'v-1', session_token: 's-1', events: [{ type: 'view' }] }
  end

  # No Authorization header anywhere in this spec, on purpose: the caller is a
  # visitor's browser on the dealer's own hostname.
  def beacon(body = payload, page_id: page.id)
    post "/pv/#{page_id}", params: body.to_json, headers: { 'Content-Type' => 'application/json' }
  end

  it 'accepts a beacon with no authentication' do
    beacon

    expect(response).to have_http_status(:no_content)
    expect(PageVisit.where(website_page_id: page.id).count).to eq(1)
  end

  # Public::SitesController caches published pages at the edge for 5 minutes.
  # If the beacon were cacheable too, one visitor would be reported for the day.
  it 'is never cached' do
    beacon
    expect(response.headers['Cache-Control']).to match(/no-store/)
  end

  it 'allows cross-origin posts from any dealer domain' do
    beacon
    expect(response.headers['Access-Control-Allow-Origin']).to eq('*')
  end

  it 'answers the preflight' do
    process :options, "/pv/#{page.id}"
    expect(response).to have_http_status(:no_content)
    expect(response.headers['Access-Control-Allow-Methods']).to include('POST')
  end

  it 'records events and scroll progress' do
    beacon(payload.merge(max_scroll_depth: 75, events: [{ type: 'view' }, { type: 'scroll_75' }]))

    visit = PageVisit.last
    expect(visit.max_scroll_depth).to eq(75)
    expect(visit.page_visit_events.pluck(:event_type)).to contain_exactly('view', 'scroll_75')
  end

  it 'rejects a beacon with no tokens' do
    beacon({ events: [{ type: 'view' }] })
    expect(response).to have_http_status(:bad_request)
  end

  it '404s for an unknown page' do
    beacon(payload, page_id: 999_999)
    expect(response).to have_http_status(:not_found)
  end

  # This used to be restricted to landing pages, which is why page_visits held
  # nothing for dealer sites. An inventory page raises the same questions a
  # landing page does, and they are answered by the same records.
  it 'accepts an ordinary site page' do
    ordinary = site.website_pages.create!(title: 'About', path: '/about')
    beacon(payload, page_id: ordinary.id)

    expect(response).to have_http_status(:no_content)
    expect(PageVisit.where(website_page_id: ordinary.id)).to exist
  end

  it '404s for a soft-deleted landing page' do
    page.update!(is_deleted: true)
    beacon

    expect(response).to have_http_status(:not_found)
  end

  # Tracking must never break the page it is measuring.
  it 'swallows an unexpected failure rather than surfacing it' do
    allow_any_instance_of(Marketing::TrackPageVisit).to receive(:call).and_raise(StandardError, 'boom')
    beacon

    expect(response).to have_http_status(:no_content)
  end

  describe 'the reserved path prefix' do
    # Without /pv/ in RESERVED_PREFIXES the tenant catch-all answers the beacon
    # with the landing page's HTML and every visit goes unrecorded.
    it 'is exempt from the tenant website catch-all' do
      expect(Constraints::TenantWebsiteHost::RESERVED_PREFIXES).to include('/pv/')
    end

    it 'refuses to be swallowed on a dealer hostname' do
      constraint = Constraints::TenantWebsiteHost.new
      request = instance_double(ActionDispatch::Request, path: "/pv/#{page.id}")
      allow(Websites::RequestHost).to receive(:for).and_return('dealer.example.com')

      expect(constraint.matches?(request)).to be(false)
    end
  end
end
