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
      'https://renterinsight-api-prod.onrender.com'
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
end
