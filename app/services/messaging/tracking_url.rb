# frozen_string_literal: true

module Messaging
  # Single source of truth for the host that serves tracking endpoints:
  #   /webhooks/email/:communication_id/pixel.gif  (open pixel)
  #   /t/:token                                    (click redirect)
  #   /u/:token                                    (unsubscribe)
  #
  # These routes live on the Rails API server, NOT the frontend app. Resolving
  # them from a frontend variable (APP_URL / FRONTEND_URL / APP_BASE_URL) breaks
  # tracking *silently*: the SPA answers every path with its HTML shell, the
  # <img> never loads a gif, and nothing is recorded. That is exactly how open
  # tracking sat dead across every CommunicationService email — the pixel fell
  # back to the frontend host while click links used the API host and worked.
  #
  # Never resolve a tracking URL from a frontend variable. Use this.
  module TrackingUrl
    def self.base
      (ENV['DMS_API_URL'].presence ||
       ENV['CAMPAIGN_BASE_URL'].presence ||
       default_base).to_s.chomp('/')
    end

    # Falling back to the staging API from production would send real recipients'
    # opens to the wrong environment, so key the default off the environment.
    def self.default_base
      if Rails.env.production?
        'https://renterinsight-api-prod.onrender.com'
      else
        'https://renterinsight-api-staging.onrender.com'
      end
    end
  end
end
