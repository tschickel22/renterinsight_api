# frozen_string_literal: true

Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    # Local development origins
    local_origins = [
      %r{\Ahttp://localhost:\d+\z},
      %r{\Ahttps://localhost:\d+\z},
      %r{\Ahttp://127\.0\.0\.1:\d+\z},
      %r{\Ahttps://127\.0\.0\.1:\d+\z},
      'http://localhost:5173',
      'https://localhost:5173',
      'http://localhost:3000',
      'https://localhost:3000',
      'http://127.0.0.1:5173',
      'https://127.0.0.1:5173',
      'http://127.0.0.1:3000',
      'https://127.0.0.1:3000'
    ]

    # Production/Staging origins from environment variable (comma-separated)
    env_origins = ENV['CORS_ORIGINS']&.split(',')&.map(&:strip) || []

    # Fallback origins if CORS_ORIGINS not set
    fallback_origins = [
      'https://crm.landlordinsight.com',
      'https://dms.renterinsight.com',
      'https://staging.crm.landlordinsight.com',
      'https://staging-dms.renterinsight.com',
      'https://renterinsight-api-staging.onrender.com',
      'https://renterinsight-api-prod.onrender.com',
      'https://dealertide.com',
      'https://www.dealertide.com',
      'https://staging.dealertide.com'
    ]

    # Combine all origins
    all_origins = local_origins + env_origins + fallback_origins

    origins(*all_origins.uniq)

    resource '*',
             headers: :any,
             methods: [:get, :post, :put, :patch, :delete, :options, :head],
             credentials: true,
             expose: ['Content-Type', 'Authorization', 'Content-Disposition']
  end

  # Tenant sites, on any hostname.
  #
  # A dealer site is served from its own origin: a platform subdomain today, the
  # dealer's own domain once they buy one. Neither can be in the allowlist above
  # — subdomains are created at runtime and custom domains are not knowable in an
  # initializer without a database read on every request. Measured on a freshly
  # published site: the API answered 200 with no Access-Control-Allow-Origin
  # header, so the browser threw the response away and the inventory grid stayed
  # empty. The demo looked fine only because it renders on staging.dealertide.com,
  # which is allowlisted.
  #
  # This block is second on purpose. Rack::Cors takes the first block whose origin
  # AND resource match, so an allowlisted origin still gets the credentialed rules
  # above; only origins that fail that list fall through to here.
  #
  # Every path below is already unauthenticated and scoped by a token or a public
  # slug, and none of them read cookies, hence credentials: false. This does not
  # widen what can be reached — a script or curl could always call these — it only
  # lets a browser on a dealer's own domain read the answer.
  allow do
    origins '*'

    # Inventory and land: browse, detail, filters, and the lead POST behind the
    # contact button on a listing.
    resource '/public/*',
             headers: :any,
             methods: %i[get post options head],
             credentials: false

    # The visitor tracking beacon.
    #
    # It posts to the absolute API host (VITE_RAILS_API_URL), so from a dealer's
    # own hostname it is cross-origin, and Rack::Cors sits in front of every
    # request and rejects the preflight before PageTrackingController's own CORS
    # headers can apply. Measured in a browser on a live tenant site: the
    # relative path returned 204 while the absolute one failed to fetch, so not
    # one visit was recorded even though the endpoint worked.
    # Crash reports from a dealer hostname or a shared demo.
    resource '/client_errors',
             headers: :any,
             methods: %i[post options],
             credentials: false

    # The concierge, which answers visitors on a dealer's own hostname.
    resource '/concierge/*',
             headers: :any,
             methods: %i[post options],
             credentials: false

    # The demo link beacon, same reasoning: a shared preview can be opened from
    # anywhere, and the token in the URL is the authorisation.
    resource '/dv/*',
             headers: :any,
             methods: %i[post options],
             credentials: false

    resource '/pv/*',
             headers: :any,
             methods: %i[post options],
             credentials: false

    # The lead form on a landing page.
    #
    # An imported design keeps its own form markup and posts it to the absolute
    # API host, so from the dealer's own hostname this is cross-origin like the
    # tracking beacon above. Rack::Cors answers the preflight before the
    # controller is reached, and with no rule here it answered 200 carrying no
    # Access-Control-Allow-Origin at all. The browser then refused the POST,
    # fetch threw, and the visitor was told "that did not send" while the
    # endpoint itself was working perfectly: submitting the same body by hand
    # created the lead. A form on an ad landing page failing this way loses the
    # click and the spend behind it.
    #
    # GET is the form's own definition, fetched to render a hosted form.
    %w[/api/f/* /f/*].each do |path|
      resource path,
               headers: :any,
               methods: %i[get post options head],
               credentials: false
    end

    # Blog posts and categories rendered into a site's pages.
    resource '/api/public/*',
             headers: :any,
             methods: %i[get options head],
             credentials: false

    # The site payload itself. Named one by one rather than as /api/v1/* so that
    # opening these cannot drift into opening the authenticated API.
    %w[
      /api/v1/websites/by_slug_public/*
      /api/v1/websites/by_token/*
      /api/v1/site_content_profiles/by_token/*
    ].each do |path|
      resource path,
               headers: :any,
               methods: %i[get options head],
               credentials: false
    end
  end
end
