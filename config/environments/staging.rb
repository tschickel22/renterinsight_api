require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled in staging (set to true for more debugging).
  config.consider_all_requests_local = false

  # Cache assets for far-future expiry since they are all digest stamped.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # Store uploaded files on the local file system (see config/storage.yml for options).
  # Using :local for staging environment (disk-based storage)
  config.active_storage.service = :local

  # Assume all access to the app is happening through a SSL-terminating reverse proxy.
  config.assume_ssl = true

  # For staging, we can be less strict about SSL
  config.force_ssl = false

  # Allow WebSocket connections from frontend domains (ActionCable CORS)
  config.action_cable.allowed_request_origins = (ENV['CORS_ORIGINS']&.split(',')&.map(&:strip) || []) + [
    'https://staging.crm.landlordinsight.com',
    'https://staging-dms.renterinsight.com',
    'https://*.netlify.app',
    /https:\/\/.*\.netlify\.app/
  ]

  # Log to STDOUT with the current request id as a default log tag.
  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)

  # Use info level for staging logs (can change to "debug" for more verbose logging)
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Show deprecations in staging to catch issues before production.
  config.active_support.report_deprecations = true

  # Set host for mailer templates
  config.action_mailer.default_url_options = { 
    host: ENV.fetch("STAGING_HOST", "renterinsight-api-staging.onrender.com") 
  }

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in staging.
  config.active_record.attributes_for_inspect = [ :id ]

  # Allow requests from staging domain and localhost for testing
  # config.hosts = [
  #   "renterinsight-api-staging.onrender.com",
  #   /.*\.onrender\.com/,
  #   "localhost"
  # ]
end
