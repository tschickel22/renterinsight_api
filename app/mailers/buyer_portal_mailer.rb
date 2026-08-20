# frozen_string_literal: true

class BuyerPortalMailer < ApplicationMailer
  default from: ENV.fetch('PORTAL_FROM_EMAIL', 'portal@renterinsight.com')
  
  # Welcome email when buyer first gets portal access
  def welcome_email(buyer_access)
    @buyer_access = buyer_access
    @buyer = buyer_access.buyer
    @company_name = dealership_name(buyer_access)
    @portal_url = portal_login_url
    @preferences_url = portal_app_url('settings')

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
    @company_name = dealership_name(buyer_access)
    
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
    @company_name = dealership_name(buyer_access)
    @portal_url = portal_login_url
    @reset_link = portal_auth_url("client/reset-password/new?token=#{buyer_access.reset_token}")
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
    @company_name = dealership_name(buyer_access)
    @portal_url = portal_login_url
    @preferences_url = portal_app_url('settings')
    # The portal lists quotes; there is no per-quote route to deep link to.
    @quote_url = portal_app_url('quotes')
    
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
    @company_name = dealership_name(buyer_access)
    @admin_url = ENV.fetch('ADMIN_URL', 'https://admin.renterinsight.com')
    @quote_url = "#{@admin_url}/quotes/#{quote.id}"
    
    mail(
      to: ENV.fetch('SALES_EMAIL', 'sales@renterinsight.com'),
      subject: "Quote #{quote.quote_number} Rejected by #{buyer_access.buyer.full_name rescue buyer_access.email}"
    )
  end
  
  # Loan payment receipt
  def loan_payment_receipt(loan, payment)
    @loan = loan
    @payment = payment
    @buyer = loan.borrower
    @company_name = dealership_name(loan)
    @portal_url = portal_login_url
    @loan_url = portal_app_url('loans')
    
    buyer_email = @buyer.respond_to?(:email) ? @buyer.email : nil
    return unless buyer_email.present?
    
    # Configure SMTP from platform settings
    configure_mailer_from_settings
    
    # Get from email from settings or ENV
    from_email = get_from_email
    from_name = get_from_name
    
    message = mail(
      to: buyer_email,
      from: "#{from_name} <#{from_email}>",
      subject: "Payment Receipt for Loan #{loan.loan_number}"
    )
    
    Rails.logger.info "Loan payment receipt sent to #{buyer_email} for loan #{loan.loan_number}"
    message
  end
  
  # Internal notification when buyer replies in portal
  def communication_reply_notification(communication)
    @communication = communication
    @buyer = communication.communicable
    @thread = communication.communication_thread
    @company_name = dealership_name(communication)
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

  # The dealership's name, not the platform's. A buyer bought their home from a
  # specific dealer, so portal mail has to carry that dealer's brand. See the
  # BRAND KERNEL section of CLAUDE.md, which deliberately exempts customer facing
  # mail from the platform kernel. Falls back to the platform brand only when no
  # company can be resolved, which should not happen: every buyer_portal_accesses
  # row in production has a company_id.
  def dealership_name(record)
    company =
      if record.respond_to?(:company) && record.company.present?
        record.company
      elsif record.respond_to?(:buyer) && record.buyer.respond_to?(:company)
        record.buyer.company
      end

    company&.name.presence || Brand.current.name
  end

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
  
  # Only the *sender identity* falls back to the platform brand. This mailer's
  # content stays dealership-branded (@company.name) by design — see the brand
  # kernel notes in CLAUDE.md.
  def get_from_email
    settings = get_platform_settings
    settings&.dig('communications', 'email', 'fromEmail') ||
      ENV['PORTAL_FROM_EMAIL'] ||
      ENV['MAILER_FROM'] ||
      Brand.from_email
  end

  def get_from_name
    settings = get_platform_settings
    settings&.dig('communications', 'email', 'fromName') ||
      ENV['EMAIL_FROM_NAME'] ||
      ENV['COMPANY_NAME'] ||
      Brand.from_name
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

  private

  # The buyer portal is served inside the main SPA, not on a host of its own.
  #
  # Its auth pages sit at the root (/client/login, /client/reset-password/new)
  # while everything behind the login lives under /portalclient. PORTAL_URL
  # predates that split: it used to name a bare portal host, so paths were
  # simply concatenated onto it. Now that it points at the SPA root, the same
  # concatenation produces 404s for anything past the login.
  #
  # Same resolution order as PushNotificationService, so a link in an email and
  # a link in a push notification land in the same place.
  def portal_root_url
    (ENV['PORTAL_URL'].presence || Brand.app_url.to_s).chomp('/')
  end

  # Pages that live at the SPA root, outside the portal shell.
  def portal_auth_url(path)
    "#{portal_root_url}/#{path.to_s.delete_prefix('/')}"
  end

  def portal_login_url
    portal_auth_url('client/login')
  end

  # Pages behind the portal login.
  def portal_app_url(path = nil)
    base = ENV['PORTAL_APP_URL'].presence&.chomp('/') || "#{portal_root_url}/portalclient"
    return base if path.blank?

    "#{base}/#{path.to_s.delete_prefix('/')}"
  end
end
