# frozen_string_literal: true

# Configure session store for QuickBooks OAuth state management
# Even though this is an API-only app, we need sessions for OAuth flows

# Determine if we're in production/staging
is_production = Rails.env.production? || ENV['RAILS_ENV'] == 'staging'

# Extract domain from FRONTEND_URL for cookie domain setting
frontend_url = ENV['FRONTEND_URL'] || 'https://localhost:5173'
frontend_domain = URI.parse(frontend_url).host rescue 'localhost'

Rails.application.config.session_store :cookie_store, 
  key: '_renterinsight_api_session',
  same_site: :none,  # Required for cross-domain OAuth flows
  secure: is_production,  # Only send over HTTPS in production
  httponly: true,  # Prevent JavaScript access
  expire_after: 30.minutes,  # OAuth sessions should be short-lived
  domain: :all  # Allow cookie to work across subdomains
