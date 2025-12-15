# frozen_string_literal: true

# Configure ActionMailer to use Platform/Company Settings
# This runs before each email is sent

ActionMailer::Base.class_eval do
  # Override delivery method to use Settings
  def self.delivery_method_from_settings
    settings = begin
      Setting.get('Platform', 0, 'communications')
    rescue StandardError
      nil
    end

    return :test unless settings&.dig('email', 'isEnabled')

    email_config = settings['email']
    return :test unless email_config

    # Configure SMTP settings from Platform Settings
    if email_config['provider'] == 'smtp'
      ActionMailer::Base.smtp_settings = {
        address: email_config['smtpHost'] || 'smtp.gmail.com',
        port: (email_config['smtpPort'] || 587).to_i,
        user_name: email_config['smtpUsername'],
        password: decrypt_if_needed(email_config['smtpPassword']),
        authentication: email_config['smtpAuthentication'] || 'plain',
        enable_starttls_auto: email_config['smtpEnableStarttls'].nil? ? true : email_config['smtpEnableStarttls']
      }
      :smtp
    else
      :test
    end
  end

  def self.decrypt_if_needed(value)
    return nil unless value
    return value unless value.is_a?(String) && value.start_with?('encrypted:')

    encrypted_data = value.sub('encrypted:', '')
    secret_key = ENV['SETTINGS_ENCRYPTION_KEY'] || Rails.application.secret_key_base
    key = ActiveSupport::KeyGenerator.new(secret_key).generate_key('', 32)
    crypt = ActiveSupport::MessageEncryptor.new(key)

    crypt.decrypt_and_verify(encrypted_data)
  rescue StandardError => e
    Rails.logger.error("Failed to decrypt email password: #{e.message}")
    nil
  end

  # Set delivery method before each email
  before_action :configure_delivery_method

  private

  def configure_delivery_method
    ActionMailer::Base.delivery_method = ActionMailer::Base.delivery_method_from_settings
  end
end

Rails.logger.info("ActionMailer configured to use Settings")
