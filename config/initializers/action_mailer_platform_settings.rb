# frozen_string_literal: true

# ActionMailer configuration from Platform Settings
Rails.application.configure do
  # This will be called after Rails initializes and database is available
  config.after_initialize do
    begin
      # Get email settings from Platform Settings
      platform_settings = Setting.get('Platform', 0, 'communications')
      
      if platform_settings && platform_settings['email']
        email_config = platform_settings['email']
        
        # Only configure SMTP if enabled and has credentials
        if email_config['isEnabled'] && email_config['smtpHost'].present?
          Rails.logger.info "📧 Configuring ActionMailer from Platform Settings"
          
          # Decrypt password if encrypted
          smtp_password = email_config['smtpPassword']
          if smtp_password&.start_with?('encrypted:')
            encrypted_data = smtp_password.sub('encrypted:', '')
            secret_key = ENV['SETTINGS_ENCRYPTION_KEY'] || Rails.application.secret_key_base
            key = ActiveSupport::KeyGenerator.new(secret_key).generate_key('', 32)
            crypt = ActiveSupport::MessageEncryptor.new(key)
            smtp_password = crypt.decrypt_and_verify(encrypted_data) rescue smtp_password
          end
          
          ActionMailer::Base.delivery_method = :smtp
          ActionMailer::Base.perform_deliveries = true
          ActionMailer::Base.raise_delivery_errors = true
          
          ActionMailer::Base.smtp_settings = {
            address: email_config['smtpHost'],
            port: email_config['smtpPort'] || 587,
            user_name: email_config['smtpUsername'],
            password: smtp_password,
            authentication: 'plain',
            enable_starttls_auto: true,
            domain: email_config['smtpHost']&.split('.')&.last(2)&.join('.')
          }
          
          Rails.logger.info "✅ ActionMailer configured with SMTP: #{email_config['smtpHost']}"
        else
          Rails.logger.info "📧 Email not enabled in Platform Settings, using default config"
        end
      else
        Rails.logger.info "📧 No Platform email settings found, using default config"
      end
    rescue => e
      Rails.logger.warn "⚠️  Failed to configure ActionMailer from Platform Settings: #{e.message}"
      Rails.logger.warn "   Using default email configuration"
    end
  end
end
