# frozen_string_literal: true

Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins %r{\Ahttp://localhost:\d+\z}, 
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
            'https://127.0.0.1:3000',
            'https://crm.landlordinsight.com',
            'https://staging.crm.landlordinsight.com',
            'https://renterinsight-api-staging.onrender.com',
            'https://renterinsight-api-prod.onrender.com'

    resource '*',
             headers: :any,
             methods: [:get, :post, :put, :patch, :delete, :options, :head],
             credentials: true,
             expose: ['Content-Type', 'Authorization', 'Content-Disposition']
  end
end
