# frozen_string_literal: true

class MagicLinkMailer < ApplicationMailer
  # Admin/Staff magic link email
  def admin_magic_link(user, token)
    @user = user
    @token = token
    @company_name = ENV.fetch('COMPANY_NAME', 'RenterInsight')
    
    # Get the frontend URL - use 5173 for Vite dev server
    frontend_url = ENV['FRONTEND_URL'] || 'http://localhost:5173'
    @magic_link = "#{frontend_url}/magic-link?token=#{token}"
    @expires_in = '15 minutes'
    
    # Configure SMTP from platform settings
    configure_mailer_from_settings
    
    # Get from email from settings or ENV
    from_email = get_from_email
    from_name = get_from_name
    
    mail(
      to: user.email,
      from: "#{from_name} <#{from_email}>",
      subject: "Your Magic Link to #{@company_name}"
    )
  end
  
  private
  
  # Configure ActionMailer SMTP from platform settings
  def configure_mailer_from_settings
    settings = get_platform_settings
    return unless settings
    
    email_config = settings.dig('communications', 'email')
    return unless email_config && email_config['isEnabled']
    
    # Decrypt password if encrypted
    password = email_config['smtpPassword']
    if password&.start_with?('encrypted:')
      password = decrypt_setting(password)
    end
    
    smtp_config = {
      address: email_config['smtpHost'] || 'smtp.gmail.com',
      port: (email_config['smtpPort'] || 587).to_i,
      user_name: email_config['smtpUsername'],
      password: password,
      authentication: email_config['smtpAuthentication'] || 'plain',
      enable_starttls_auto: email_config['smtpEnableStarttls'].nil? ? true : email_config['smtpEnableStarttls']
    }
    
    ActionMailer::Base.delivery_method = :smtp
    ActionMailer::Base.smtp_settings = smtp_config
    ActionMailer::Base.perform_deliveries = true
    ActionMailer::Base.raise_delivery_errors = true
    
    Rails.logger.info("📧 MagicLinkMailer SMTP configured: #{email_config['smtpHost']}:#{email_config['smtpPort']}")
  rescue StandardError => e
    Rails.logger.error("❌ Failed to configure MagicLinkMailer: #{e.message}")
  end
  
  def get_platform_settings
    Setting.get('Platform', 0, 'communications')
  rescue StandardError => e
    Rails.logger.warn("Failed to get platform settings: #{e.message}")
    nil
  end
  
  def get_from_email
    settings = get_platform_settings
    settings&.dig('communications', 'email', 'fromEmail') || 
      ENV['MAILER_FROM'] || 
      'noreply@renterinsight.com'
  end
  
  def get_from_name
    settings = get_platform_settings
    settings&.dig('communications', 'email', 'fromName') || 
      ENV['EMAIL_FROM_NAME'] || 
      ENV['COMPANY_NAME'] || 
      'RenterInsight'
  end
  
  def decrypt_setting(encrypted_value)
    return encrypted_value unless encrypted_value.start_with?('encrypted:')
    
    encrypted_data = encrypted_value.sub('encrypted:', '')
    secret_key = ENV['SETTINGS_ENCRYPTION_KEY'] || Rails.application.secret_key_base
    key = ActiveSupport::KeyGenerator.new(secret_key).generate_key('', 32)
    crypt = ActiveSupport::MessageEncryptor.new(key)
    
    crypt.decrypt_and_verify(encrypted_data)
  rescue StandardError => e
    Rails.logger.error("Failed to decrypt setting: #{e.message}")
    nil
  end
end
