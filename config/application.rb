require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module RenterinsightApi
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.0

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    # FIXED: Ignore debug/diagnostic scripts so they don't auto-execute during boot
    config.autoload_lib(ignore: %w[
      assets 
      tasks
      scripts
    ])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Only loads a smaller set of middleware suitable for API only apps.
    # Middleware like session, flash, cookies can be added back manually.
    # Skip views, helpers and assets when generating a new resource.
    config.api_only = true
    
    # Enable sessions for OAuth flows (QuickBooks, etc.)
    config.middleware.use ActionDispatch::Cookies
    config.middleware.use ActionDispatch::Session::CookieStore
    
    # Active Record Encryption configuration for Rails 7+
    # Required for models using `encrypts` (e.g., UserEmailConnection.smtp_password)
    config.before_configuration do
      if ENV['ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY'].present?
        # Use environment variables (staging/production)
        ENV['ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY'] # Already set
      elsif Rails.env.development? || Rails.env.test?
        # For development/test, derive keys from a stable base
        require 'digest'
        base = 'renterinsight-dev-encryption-base-key-2024'
        
        ENV['ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY'] ||= Digest::SHA256.hexdigest("#{base}-primary")[0..31]
        ENV['ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY'] ||= Digest::SHA256.hexdigest("#{base}-deterministic")[0..31]
        ENV['ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT'] ||= Digest::SHA256.hexdigest("#{base}-salt")[0..31]
      end
    end
  end
end
