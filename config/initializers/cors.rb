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
