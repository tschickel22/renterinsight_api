# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Public::Sites', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:location) { company.locations.create!(name: 'Showroom') }

  let(:website) do
    Website.create!(company_id: company.id, location_id: location.id, name: 'Sunshine RV',
                    slug: "s-#{SecureRandom.hex(4)}", status: 'published',
                    brand: { 'company_name' => 'Sunshine RV', 'description' => 'Family owned since 1982' })
  end

  let!(:home) do
    website.website_pages.create!(title: 'Home', path: '/', order: 0, is_visible: true, blocks: [])
  end

  let!(:about) do
    website.website_pages.create!(title: 'About Us', path: '/about', order: 1, is_visible: true,
                                  seo_description: 'Forty years serving Denver.', blocks: [])
  end

  let!(:domain) do
    company.company_domains.create!(hostname: 'sunshine-rv.test', website_id: website.id,
                                    verification_status: 'active')
  end

  let(:shell) do
    <<~HTML
      <!doctype html><html><head><title>Platform DMS</title>
      <meta name="description" content="generic">
      <script type="module" src="/assets/index-abc.js"></script>
      <link rel="stylesheet" href="/assets/index-abc.css">
      </head><body><div id="root"></div></body></html>
    HTML
  end

  before do
    Rails.cache.clear
    allow(Websites::SpaShell).to receive(:fetch) do
      Websites::SpaShell.absolutize(shell, 'https://spa.example.com')
    end
  end

  def get_site(path, host: 'sunshine-rv.test')
    get path, headers: { 'HTTP_HOST' => host }
  end

  describe 'serving a page' do
    it 'answers on the dealer hostname' do
      get_site('/about')

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq('text/html')
    end

    it 'sets the page title rather than the apps generic one' do
      get_site('/about')

      expect(response.body).to include('<title>About Us | Sunshine RV</title>')
      expect(response.body).not_to include('<title>Platform DMS</title>')
    end

    it 'replaces the generic description instead of emitting two' do
      get_site('/about')

      expect(response.body).to include('Forty years serving Denver.')
      expect(response.body.scan(/<meta name="description"/).length).to eq(1)
    end

    it 'sets a canonical URL on the dealer host' do
      get_site('/about')

      expect(response.body).to include('<link rel="canonical" href="https://sunshine-rv.test/about">')
    end

    it 'emits Open Graph tags so shared links render a card' do
      get_site('/about')

      expect(response.body).to include('<meta property="og:title"')
      expect(response.body).to include('<meta property="og:url" content="https://sunshine-rv.test/about">')
      expect(response.body).to include('<meta property="og:site_name" content="Sunshine RV">')
    end

    it 'rewrites relative asset paths to the SPA origin so they do not 404' do
      get_site('/about')

      expect(response.body).to include('src="https://spa.example.com/assets/index-abc.js"')
      expect(response.body).to include('href="https://spa.example.com/assets/index-abc.css"')
    end

    it 'falls back to the first page at the root path' do
      get_site('/')

      expect(response.body).to include('Home | Sunshine RV')
    end
  end

  describe 'crawler directives' do
    it 'serves robots.txt pointing at the dealers own sitemap' do
      get_site('/robots.txt')

      expect(response.body).to include('Sitemap: https://sunshine-rv.test/sitemap.xml')
      expect(response.body).to include('Allow: /')
    end

    it 'lists visible pages in the sitemap' do
      get_site('/sitemap.xml')

      expect(response.media_type).to eq('application/xml')
      expect(response.body).to include('<loc>https://sunshine-rv.test/about</loc>')
      expect(response.body).to include('<loc>https://sunshine-rv.test</loc>')
    end

    it 'omits hidden pages from the sitemap' do
      website.website_pages.create!(title: 'Secret', path: '/secret', order: 2, is_visible: false, blocks: [])

      get_site('/sitemap.xml')

      expect(response.body).not_to include('/secret')
    end
  end

  describe 'when the site should not be served' do
    it 'does not render a site for an unknown host' do
      get_site('/about', host: 'nobody.test')

      expect(response).to have_http_status(:not_found)
      expect(response.body).not_to include('Sunshine RV')
    end

    it 'leaves the API root untouched for an unknown host' do
      # An unmatched host falls through to whatever the platform would have served, rather
      # than being claimed by the site controller.
      get_site('/', host: 'nobody.test')

      expect(response.body).to eq('Renter Insight API')
    end

    it 'returns 404 once the site is unpublished' do
      website.update!(status: 'draft')
      Rails.cache.clear

      get_site('/about')

      expect(response).to have_http_status(:not_found)
    end

    it 'returns 503 rather than a broken page when the SPA origin is down' do
      allow(Websites::SpaShell).to receive(:fetch)
        .and_raise(Websites::SpaShell::ShellUnavailable, 'origin down')

      get_site('/about')

      expect(response).to have_http_status(:service_unavailable)
    end
  end

  describe 'edge caching' do
    # Without these, every visitor page view reaches Rails and dealer traffic becomes an
    # origin scaling problem instead of something Cloudflare absorbs.
    it 'lets Cloudflare cache the page and serve stale while revalidating' do
      get_site('/about')

      cache_control = response.headers['Cache-Control']
      expect(cache_control).to include('public')
      expect(cache_control).to include('s-maxage=300')
      expect(cache_control).to include('stale-while-revalidate=')
    end

    it 'sends no Set-Cookie, which would make the response uncacheable' do
      get_site('/about')

      expect(response.headers['Set-Cookie']).to be_nil
    end

    it 'returns 304 when the page has not changed' do
      get_site('/about')
      etag = response.headers['ETag']
      expect(etag).to be_present

      get '/about', headers: { 'HTTP_HOST' => 'sunshine-rv.test', 'HTTP_IF_NONE_MATCH' => etag }

      expect(response).to have_http_status(:not_modified)
    end

    it 'changes the ETag when the dealer edits the page' do
      get_site('/about')
      before = response.headers['ETag']

      about.update!(title: 'About Our Dealership')
      get_site('/about')

      expect(response.headers['ETag']).not_to eq(before)
    end

    it 'caches robots.txt and the sitemap for longer than a page' do
      get_site('/robots.txt')

      expect(response.headers['Cache-Control']).to include('s-maxage=3600')
    end

    it 'never caches an error' do
      allow(Websites::SpaShell).to receive(:fetch)
        .and_raise(Websites::SpaShell::ShellUnavailable, 'origin down')

      get_site('/about')

      expect(response.headers['Cache-Control']).to eq('no-store')
    end
  end

  describe 'route precedence' do
    it 'does not shadow the API on the platform host' do
      get '/api/v1/leads', headers: { 'HTTP_HOST' => 'renterinsight-api-prod.onrender.com' }

      expect(response.body).not_to include('Site not found')
    end

    it 'does not swallow API traffic arriving on a dealer hostname' do
      get '/api/v1/campaigns', headers: { 'HTTP_HOST' => 'sunshine-rv.test' }

      # Handled by the API stack, not rendered as the dealer's site.
      expect(response.body).not_to include('Site not found')
      expect(response.body).not_to include('id="root"')
    end

    it 'does not swallow webhook traffic arriving on a dealer hostname' do
      post '/webhooks/ses/events', params: '{}',
                                   headers: { 'HTTP_HOST' => 'sunshine-rv.test',
                                              'CONTENT_TYPE' => 'application/json' }

      expect(response.body).not_to include('id="root"')
    end

    it 'still serves the API root on the platform host' do
      get '/', headers: { 'HTTP_HOST' => 'renterinsight-api-prod.onrender.com' }

      expect(response.body).to eq('Renter Insight API')
    end
  end
end
