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

  # The app boots on a dealer hostname with no idea which site it is meant to render.
  # Rails has already resolved that, so the content ships with the page rather than being
  # fetched again — no second round trip, and no second resolution path to drift.
  describe 'embedded site payload' do
    it 'embeds the site content in the page' do
      get_site('/about')

      expect(response.body).to include('<script id="dealertide-site" type="application/json">')
      expect(response.body).to include('Sunshine RV')
    end

    it 'is valid JSON carrying the pages' do
      get_site('/about')

      json = response.body[%r{<script id="dealertide-site"[^>]*>(.*?)</script>}m, 1]
      payload = JSON.parse(json.gsub('<\\/', '</'))

      expect(payload['id']).to eq(website.id)
      expect(payload['website_pages'].map { |p| p['path'] }).to include('/about')
    end

    # Dealer copy is arbitrary text. An unescaped closing tag inside it would end the script
    # early and turn the rest of the payload into markup.
    it 'cannot be closed early by content containing a script tag' do
      about.update!(title: 'Sneaky </script><img src=x onerror=alert(1)>')

      get_site('/about')

      json = response.body[%r{<script id="dealertide-site"[^>]*>(.*?)</script>}m, 1]

      # Rails escapes HTML entities in JSON, so the angle brackets arrive as < and the
      # tag cannot terminate. Asserting the property rather than the mechanism, so this
      # still fails loudly if escape_html_entities_in_json is ever turned off.
      expect(json).not_to include('</script>')
      expect(JSON.parse(json.gsub('<\\/', '</'))['website_pages'].map { |p| p['title'] })
        .to include(a_string_including('Sneaky'))
    end

    it 'sits before the closing head tag so it exists when the app boots' do
      get_site('/about')

      payload_at = response.body.index('id="dealertide-site"')
      head_end_at = response.body.index('</head>')
      expect(payload_at).to be < head_end_at
    end
  end

  # The shell references content-hashed asset filenames. A frontend deploy makes the
  # previous ones 404, the host serves index.html for them, and the browser refuses an HTML
  # response for a module script — a blank page until caches turn over.
  describe 'stale shell recovery' do
    it 'retries once if the app never mounts' do
      get_site('/about')

      expect(response.body).to include('dt-shell-retry')
      expect(response.body).to include('window.location.replace')
    end

    # The whole point of the recovery. A plain location.reload() is normally answered from
    # the browser's own copy, so it returned the same dead HTML, spent the one allowed
    # attempt, and left the visitor on a blank page permanently. Requesting a URL neither
    # the browser nor Cloudflare has seen is what actually reaches the origin.
    it 'retries against a URL no cache has seen' do
      get_site('/about')

      expect(response.body).to include('searchParams.set(PARAM')
      expect(response.body).not_to include('location.reload()')
    end

    it 'clears the recovery parameter once the app mounts' do
      get_site('/about')

      expect(response.body).to include('searchParams.delete(PARAM)')
      expect(response.body).to include('history.replaceState')
    end

    # A module script that 404s can fire its error event while the parser is still in the
    # head. A listener registered after the bundle tags would miss it and the page would sit
    # blank for the four second timeout instead of recovering immediately.
    it 'registers the listener ahead of the bundle tags' do
      get_site('/about')

      expect(response.body.index('dt-shell-retry')).to be < response.body.index('/assets/index-abc.js')
    end

    # A dealer's tracking pixel failing, or an ad blocker killing a third-party script, is
    # not a stale shell. Reloading over it would be a self-inflicted outage on a page that
    # was rendering perfectly well.
    it 'only treats the apps own bundle as a stale shell' do
      get_site('/about')

      expect(response.body).to include("indexOf('/assets/')")
    end

    it 'guards the retry so a persistent failure cannot loop' do
      get_site('/about')

      expect(response.body).to include('sessionStorage.getItem(KEY)')
      expect(response.body).to include("sessionStorage.setItem(KEY, '1')")
    end
  end

  describe 'crawler directives' do
    it 'serves robots.txt pointing at the dealers own sitemap' do
      get_site('/robots.txt')

      expect(response.body).to include('Sitemap: https://sunshine-rv.test/sitemap.xml')
      expect(response.body).to include('Allow: /')
    end

    it 'lists the sites pages in the sitemap' do
      get_site('/sitemap.xml')

      expect(response.media_type).to eq('application/xml')
      expect(response.body).to include('<loc>https://sunshine-rv.test/about</loc>')
      expect(response.body).to include('<loc>https://sunshine-rv.test</loc>')
    end

    # A page that is not in the nav is still a live URL: find_page routes by path and only
    # excludes deleted pages. Leaving it out of the sitemap did not hide it, it just made it
    # undiscoverable, which is the worst of both. Placement is show_in_nav / show_in_footer;
    # the sitemap lists what exists.
    it 'lists a page that is linked from neither the header nor the footer' do
      website.website_pages.create!(title: 'Blog', path: '/blog', order: 2, is_visible: false,
                                    show_in_nav: false, show_in_footer: false, blocks: [])

      get_site('/sitemap.xml')

      expect(response.body).to include('<loc>https://sunshine-rv.test/blog</loc>')
    end

    it 'omits a deleted page from the sitemap' do
      website.website_pages.create!(title: 'Retired', path: '/retired', order: 3, is_deleted: true,
                                    blocks: [])

      get_site('/sitemap.xml')

      expect(response.body).not_to include('/retired')
    end
  end

  describe 'when the site should not be served' do
    it 'does not render a site for an unknown host' do
      get_site('/about', host: 'nobody.test')

      expect(response).to have_http_status(:not_found)
      expect(response.body).not_to include('Sunshine RV')
    end

    it 'answers a host that is not ours with 404, not the API root' do
      # It still falls through rather than being claimed by the site controller.
      # What it falls through TO changed: naming the platform on a hostname we do
      # not own tells a dealer's visitor something that is neither true nor theirs.
      get_site('/', host: 'nobody.test')

      expect(response).to have_http_status(:not_found)
      expect(response.body).not_to include('Renter Insight')
    end

    it 'leaves the API root untouched on our own hostname' do
      get 'http://localhost/'

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

  # These settings were stored and shown in Company Settings but read by nothing, so the
  # toggles saved a value and changed no behaviour.
  describe 'canonical host redirects' do
    it 'sends non-www to www when the domain asks for it' do
      domain.update!(redirect_type: 'non_www_to_www')

      get_site('/about')

      expect(response).to have_http_status(:moved_permanently)
      expect(response.headers['Location']).to eq('http://www.sunshine-rv.test/about')
    end

    it 'sends www to non-www when the domain asks for it' do
      domain.update!(redirect_type: 'www_to_non_www')

      get_site('/about', host: 'www.sunshine-rv.test')

      expect(response).to have_http_status(:moved_permanently)
      expect(response.headers['Location']).to eq('http://sunshine-rv.test/about')
    end

    it 'uses a 301 so search engines consolidate on one host' do
      domain.update!(redirect_type: 'non_www_to_www')

      get_site('/about')

      expect(response).to have_http_status(301)
    end

    it 'preserves the path and query string' do
      domain.update!(redirect_type: 'non_www_to_www')

      get '/inventory?make=clayton', headers: { 'HTTP_HOST' => 'sunshine-rv.test' }

      expect(response.headers['Location']).to eq('http://www.sunshine-rv.test/inventory?make=clayton')
    end

    it 'does not redirect when already on the canonical host' do
      domain.update!(redirect_type: 'www_to_non_www')

      get_site('/about')

      expect(response).to have_http_status(:ok)
    end

    it 'does not redirect when no rule is set' do
      domain.update!(redirect_type: 'none', force_www: false)

      get_site('/about')

      expect(response).to have_http_status(:ok)
    end

    it 'honours the older force_www flag when no redirect_type is chosen' do
      domain.update!(redirect_type: nil, force_www: true)

      get_site('/about')

      expect(response.headers['Location']).to eq('http://www.sunshine-rv.test/about')
    end

    it 'lets an explicit redirect_type override the older force_www flag' do
      domain.update!(redirect_type: 'www_to_non_www', force_www: true)

      get_site('/about', host: 'www.sunshine-rv.test')

      expect(response.headers['Location']).to eq('http://sunshine-rv.test/about')
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

    # Dealer sites run in this same Rails process, so an API deploy or restart takes them
    # with it. Without this a cached page that happened to expire during that window has no
    # permission to be reused, and a site that has not changed in days answers 502.
    it 'lets the edge keep serving a cached page while the origin is down' do
      get_site('/about')

      expect(response.headers['Cache-Control']).to include('stale-if-error=')
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

    # Cloudflare strips weak ETags on every plan below Enterprise, so a weak validator never
    # reached a visitor's browser. The response arrived carrying only Last-Modified, and the
    # consequences of that are covered by the Last-Modified example below.
    it 'sends a strong ETag, because Cloudflare drops weak ones' do
      get_site('/about')

      expect(response.headers['ETag']).to be_present
      expect(response.headers['ETag']).not_to start_with('W/')
    end

    # This is the bug that blanked live dealer sites.
    #
    # Last-Modified can only describe the site record. A frontend deploy changes the page
    # (the bundle filenames are content hashed) without touching the record, so a browser
    # holding a copy from before a deploy revalidated with If-Modified-Since, got a 304, and
    # went on reusing HTML pointing at a bundle that no longer existed. Every later
    # revalidation 304'd too, so the page stayed blank permanently.
    #
    # The ETag covers the shell version and does change on a deploy, so it is the only
    # validator this response may carry.
    it 'sends no Last-Modified, which cannot express a frontend deploy' do
      get_site('/about')

      expect(response.headers['Last-Modified']).to be_nil
    end

    it 'does not honour If-Modified-Since as proof the page is unchanged' do
      get_site('/about')

      get '/about', headers: { 'HTTP_HOST' => 'sunshine-rv.test',
                               'HTTP_IF_MODIFIED_SINCE' => 1.minute.from_now.httpdate }

      expect(response).to have_http_status(:ok)
    end

    # The frontend deploying has to invalidate every cached page, or visitors keep being
    # handed asset filenames that 404.
    it 'changes the ETag when the frontend bundle changes' do
      get_site('/about')
      before = response.headers['ETag']

      allow(Websites::SpaShell).to receive(:version).and_return('deploy-two')
      get_site('/about')

      expect(response.headers['ETag']).not_to eq(before)
    end

    # The embedded payload carries the whole site, so the header nav and footer links on
    # /about are built from every other page's title and flags. Keying only on the page
    # being served meant renaming a page left the old label in the nav of every page except
    # the one that was edited.
    it 'changes the ETag when a different page is renamed' do
      get_site('/about')
      before = response.headers['ETag']

      home.update!(title: 'Welcome')
      get_site('/about')

      expect(response.headers['ETag']).not_to eq(before)
    end

    it 'changes the ETag when a different page leaves the nav' do
      get_site('/about')
      before = response.headers['ETag']

      home.update!(show_in_nav: false)
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

  # Dealer traffic arrives through a Cloudflare Worker that rewrites Host to the Render
  # service hostname, because Render returns 403 for any Host it does not recognise. The
  # real hostname travels in a header.
  describe 'behind the tenant host proxy' do
    around do |example|
      original = ENV['TENANT_PROXY_SECRET']
      ENV['TENANT_PROXY_SECRET'] = 'sekret'
      Rails.cache.clear
      example.run
      original ? ENV['TENANT_PROXY_SECRET'] = original : ENV.delete('TENANT_PROXY_SECRET')
      Rails.cache.clear
    end

    def get_proxied(path, tenant_host:, secret: 'sekret')
      get path, headers: {
        'HTTP_HOST' => 'renterinsight-api-prod.onrender.com',
        'HTTP_X_TENANT_HOST' => tenant_host,
        'HTTP_X_TENANT_PROXY_SECRET' => secret
      }
    end

    it 'serves the dealer site named in the header, not the connection host' do
      get_proxied('/about', tenant_host: 'sunshine-rv.test')

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('About Us | Sunshine RV')
    end

    it 'builds the canonical URL from the dealer hostname' do
      get_proxied('/about', tenant_host: 'sunshine-rv.test')

      expect(response.body).to include('<link rel="canonical" href="https://sunshine-rv.test/about">')
    end

    # Without the secret check, anyone could call the Render hostname claiming to be a
    # dealer's domain and be served that dealer's site under it.
    it 'ignores a forged header without the secret' do
      get_proxied('/about', tenant_host: 'sunshine-rv.test', secret: 'wrong')

      expect(response.body).not_to include('Sunshine RV')
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

  # A landing page carries its own publish state, and the public side read none
  # of it: a campaign page was reachable at its path from the moment it existed.
  describe 'an unpublished landing page' do
    let!(:draft) do
      website.website_pages.create!(title: 'Facebook Offer', path: '/fb', order: 5,
                                    page_kind: 'landing', blocks: [])
    end

    it 'is not served' do
      get 'http://sunshine-rv.test/fb'
      expect(response).to have_http_status(:not_found)
    end

    it 'is served once published' do
      draft.publish!

      get 'http://sunshine-rv.test/fb'
      expect(response).to have_http_status(:ok)
    end

    it 'keeps its blocks out of the payload a browser receives' do
      get 'http://sunshine-rv.test/about'
      expect(response.body).not_to include('Facebook Offer')
    end

    it 'stays out of the sitemap' do
      get 'http://sunshine-rv.test/sitemap.xml'
      expect(response.body).not_to include('/fb')
    end

    # An ordinary page has no publish state of its own. Applying the same gate to
    # it would take a live dealer's site away.
    it 'does not gate an ordinary page the same way' do
      get 'http://sunshine-rv.test/about'
      expect(response).to have_http_status(:ok)
    end
  end

  # A hostname that reaches us and resolves to nothing used to fall through to
  # the API root and answer a dealer's visitor with the platform's own name.
  describe 'a hostname linked to no website' do
    let!(:unlinked) do
      company.company_domains.create!(hostname: 'unassigned.test', verification_status: 'active')
    end

    it 'answers 404 rather than naming the platform' do
      get 'http://unassigned.test/'
      expect(response).to have_http_status(:not_found)
      expect(response.body).not_to include('Renter Insight')
    end
  end

  # A pixel that only fires once React has mounted misses whoever leaves before
  # that, which on an ad landing page is the population being measured. Meta's
  # own install check reads the delivered HTML too, so a client-injected pixel
  # reports itself as not installed.
  describe 'analytics and pixels in the delivered HTML' do
    it 'writes the site\'s configured tags into the shell' do
      website.update!(tracking_config: { 'google_analytics_id' => 'G-SITE1234' })

      get_site('/about')

      expect(response.body).to include('gtag/js?id=G-SITE1234')
    end

    it "lets a landing page carry its own pixel over the site's" do
      website.update!(tracking_config: { 'facebook_pixel_id' => '1111111111' })
      website.website_pages.create!(title: 'Offer', path: '/fb', page_kind: 'landing',
                                    blocks: [], published_at: Time.current, is_visible: true,
                                    tracking_config: { 'facebook_pixel_id' => '2222222222' })

      get_site('/fb')

      # The site's id still appears in the JSON payload the app boots from; what
      # matters is which one the pixel actually initialises with.
      expect(response.body).to include("fbq('init', '2222222222')")
      expect(response.body).not_to include("fbq('init', '1111111111')")
    end

    it 'puts the GTM noscript half after the opening body tag' do
      website.update!(tracking_config: { 'google_tag_manager_id' => 'GTM-ABC123' })

      get_site('/about')

      expect(response.body).to match(%r{<body[^>]*>\s*<noscript><iframe src="https://www\.googletagmanager\.com/ns\.html})
    end

    # Measurement is worth losing. The dealer's site is not.
    it 'still serves the page when the config is unusable' do
      website.update!(tracking_config: { 'custom_scripts' => 'not a hash' })

      get_site('/about')

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Sunshine RV')
    end

    # SiteRenderer injects the custom head/body fields client side, which is
    # right for the builder preview and a shared demo. On a live site both would
    # run and every snippet would fire twice.
    it 'tells the client that these tags are already in the document' do
      website.update!(tracking_config: { 'google_analytics_id' => 'G-SITE1234' })

      get_site('/about')

      expect(response.body).to include('<meta name="dt-tracking" content="server">')
    end

    it 'leaves no marker when there is nothing to track' do
      get_site('/about')

      expect(response.body).not_to include('name="dt-tracking"')
    end
  end
end
