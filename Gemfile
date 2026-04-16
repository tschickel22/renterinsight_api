source "https://rubygems.org"

# Ruby version
ruby "3.2.6"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.0.3"
# Use PostgreSQL as the database for Active Record (all environments)
gem "pg", "~> 1.5"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"
# Build JSON APIs with ease [https://github.com/rails/jbuilder]
# gem "jbuilder"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
# gem "bcrypt", "~> 3.1.7"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Use the database-backed adapters for Rails.cache, Active Job, and Action Cable
gem "solid_cache"
gem "solid_queue"
gem "solid_cable"

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Deploy this application anywhere as a Docker container [https://kamal-deploy.org]
gem "kamal", require: false

# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem "thruster", require: false

# Use Active Storage variants [https://guides.rubyonrails.org/active_storage_overview.html#transforming-images]
# gem "image_processing", "~> 1.2"

# Use Rack CORS for handling Cross-Origin Resource Sharing (CORS), making cross-origin Ajax possible
# gem "rack-cors"

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false
  
  # Load environment variables from .env file
  gem 'dotenv-rails'
end

gem "rack-cors", "~> 3.0"
gem 'liquid'
gem 'sidekiq'
gem 'sidekiq-cron', '~> 1.12'  # Scheduled background jobs

group :test do
  gem 'rspec-rails'
end

group :development, :test do
  gem 'factory_bot_rails'
end

group :test do
  gem 'shoulda-matchers'
end

# Time-series grouping for analytics
gem 'groupdate'

# Phase 4A - Portal Authentication
gem 'bcrypt', '~> 3.1.7'
gem 'jwt'

# SMS/Twilio for password reset
gem 'twilio-ruby', '~> 7.3'

# PDF Generation
gem 'prawn', '~> 2.4'
gem 'prawn-table', '~> 0.2'

gem 'rotp', '~> 6.3'

# XML parsing for payment gateway integration (Zego)
gem 'xml-simple', '~> 1.1'

# HTTP requests for QuickBooks API integration
gem 'httparty'

# AWS SDK for SES email sending
gem 'aws-sdk-ses', '~> 1.0'
# AWS SDK for S3 file storage
gem 'aws-sdk-s3', '~> 1.0'

# Additional Communication Services
gem 'sendgrid-ruby'
gem 'aws-sdk-sns', '~> 1.0'

gem "roo", "~> 3.0"
gem "caxlsx", "~> 4.1"

# PDF merging for multi-document agreements
gem 'combine_pdf', '~> 1.0'

# Puma memory management — auto-restart workers that exceed memory limits
# Prevents OOM kills on Render Starter (512MB)
gem 'puma_worker_killer', '~> 0.3'

# PDF text extraction with position data (for AI vision scan field placement)
gem 'pdf-reader', '~> 2.12'

# Web scraping for floor plan data
gem 'selenium-webdriver'
