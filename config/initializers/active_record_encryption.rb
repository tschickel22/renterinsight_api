# frozen_string_literal: true

# Configure Active Record Encryption for Rails 7+
# This is required for models using `encrypts` attribute encryption
#
# For production: Use Rails credentials (bin/rails credentials:edit)
# For development: Use environment variables or generate keys below

if Rails.application.credentials.dig(:active_record_encryption, :primary_key).blank?
  # Check for environment variables first
  if ENV['ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY'].present?
    Rails.application.config.active_record.encryption.primary_key = ENV['ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY']
    Rails.application.config.active_record.encryption.deterministic_key = ENV['ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY']
    Rails.application.config.active_record.encryption.key_derivation_salt = ENV['ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT']
  else
    # No explicit encryption keys configured — derive from secret_key_base.
    # For production, set ENV vars or Rails credentials for proper key management.
    require 'digest'

    base = Rails.application.secret_key_base || 'development-fallback-key-not-for-production'

    Rails.application.config.active_record.encryption.primary_key = Digest::SHA256.hexdigest("#{base}-primary")[0..31]
    Rails.application.config.active_record.encryption.deterministic_key = Digest::SHA256.hexdigest("#{base}-deterministic")[0..31]
    Rails.application.config.active_record.encryption.key_derivation_salt = Digest::SHA256.hexdigest("#{base}-salt")[0..31]

    Rails.logger.info "[ActiveRecord Encryption] Using derived keys for #{Rails.env} environment"
  end
end
