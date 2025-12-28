# frozen_string_literal: true

# Configure session store for QuickBooks OAuth state management
# Even though this is an API-only app, we need sessions for OAuth flows
Rails.application.config.session_store :cookie_store, 
  key: '_renterinsight_api_session',
  same_site: :lax,
  secure: Rails.env.production?
