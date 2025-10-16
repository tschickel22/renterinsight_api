# frozen_string_literal: true

class BuyerPortalMailer < ApplicationMailer
  default from: ENV.fetch('PORTAL_FROM_EMAIL', 'portal@renterinsight.com')
  
  # Welcome email when buyer first gets portal access
  def welcome_email(buyer_access)
    @buyer_access = buyer_access
    @buyer = buyer_access.buyer
    @company_name = ENV.fetch('COMPANY_NAME', 'RenterInsight')
    @portal_url = ENV.fetch('PORTAL_URL', 'https://portal.renterinsight.com')
    
    message = mail(
      to: buyer_access.email,
      subject: "Welcome to #{@company_name} Buyer Portal"
    )
    
    Rails.logger.info "Welcome email sent to #{buyer_access.email}"
    message
  end
  
  # Magic link for passwordless login
  def magic_link_email(buyer_access)
    @buyer_access = buyer_access
    @buyer = buyer_access.buyer
    @company_name = ENV.fetch('COMPANY_NAME', 'RenterInsight')
    
    # Get the frontend URL - use 5173 for Vite dev server
    frontend_url = ENV['FRONTEND_URL'] || 'http://localhost:5173'
    @magic_link = "#{frontend_url}/magic-link?token=#{buyer_access.login_token}"
    @expires_in = '15 minutes'
    
    # Configure SMTP from platform settings
    configure_mailer_from_settings
    
    # Get from email from settings or ENV
    from_email = get_from_email
    from_name = get_from_name
    
    mail(
      to: buyer_access.email,
      from: "#{from_name} <#{from_email}>",
      subject: "Your Magic Link to #{@company_name}"
    )
  end
  
  # Password reset email
  def password_reset_email(buyer_access)
    @buyer_access = buyer_access
    @buyer = buyer_access.buyer
    @company_name = ENV.fetch('COMPANY_NAME', 'RenterInsight')
    @portal_url = ENV.fetch('PORTAL_URL', 'https://portal.renterinsight.com')
    @reset_link = "#{@portal_url}/auth/reset-password?token=#{buyer_access.reset_token}"
    @expires_in = '1 hour'
    
    mail(
      to: buyer_access.email,
      subject: "Reset Your #{@company_name} Portal Password"
    )
  end
  
  # Quote acceptance confirmation
  def quote_acceptance_email(quote, buyer_access)
    @quote = quote
    @buyer_access = buyer_access
    @buyer = buyer_access.buyer
    @company_name = ENV.fetch('COMPANY_NAME', 'RenterInsight')
    @portal_url = ENV.fetch('PORTAL_URL', 'https://portal.renterinsight.com')
    @quote_url = "#{@portal_url}/quotes/#{quote.id}"
    
    mail(
      to: buyer_access.email,
      subject: "Quote #{quote.quote_number} Accepted - Thank You!"
    )
  end
  
  # Internal notification for quote rejection
  def quote_rejection_notification(quote, buyer_access)
    @quote = quote
    @buyer_access = buyer_access
    @buyer = buyer_access.buyer
    @company_name = ENV.fetch('COMPANY_NAME', 'RenterInsight')
    @admin_url = ENV.fetch('ADMIN_URL', 'https://admin.renterinsight.com')
    @quote_url = "#{@admin_url}/quotes/#{quote.id}"
    
    mail(
      to: ENV.fetch('SALES_EMAIL', 'sales@renterinsight.com'),
      subject: "Quote #{quote.quote_number} Rejected by #{buyer_access.buyer.full_name rescue buyer_access.email}"
    )
  end
  
  # Internal notification when buyer replies in portal
  def communication_reply_notification(communication)
    @communication = communication
    @buyer = communication.communicable
    @thread = communication.communication_thread
    @company_name = ENV.fetch('COMPANY_NAME', 'RenterInsight')
    @admin_url = ENV.fetch('ADMIN_URL', 'https://admin.renterinsight.com')
    @thread_url = "#{@admin_url}/communications/threads/#{@thread.id}"
    
    buyer_name = @buyer.respond_to?(:full_name) ? @buyer.full_name : @buyer.email
    
    message = mail(
      to: ENV.fetch('SUPPORT_EMAIL', 'support@renterinsight.com'),
      subject: "New Reply from #{buyer_name} in Portal"
    )
    
    Rails.logger.info "Reply notification sent for thread: #{@thread.id}"
    message
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
    
    Rails.logger.info("📧 BuyerPortalMailer SMTP configured: #{email_config['smtpHost']}:#{email_config['smtpPort']}")
  rescue StandardError => e
    Rails.logger.error("❌ Failed to configure BuyerPortalMailer: #{e.message}")
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
      ENV['PORTAL_FROM_EMAIL'] || 
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
