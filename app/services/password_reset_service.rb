# frozen_string_literal: true

class PasswordResetService
  class RateLimitError < StandardError; end
  class UserNotFoundError < StandardError; end
  class DeliveryDisabledError < StandardError; end
  class DeliveryFailedError < StandardError; end

  def initialize(ip_address: nil, user_agent: nil)
    @ip_address = ip_address
    @user_agent = user_agent
  end

  def request_reset(email: nil, phone: nil, delivery_method:, user_type:)
    # Normalize phone number if provided (adds country code automatically)
    phone = PhoneNumberService.normalize(phone) if phone.present?
    
    identifier = delivery_method == 'email' ? email : phone

    # Rate limiting check
    raise RateLimitError, 'Too many reset requests. Please try again later.' if rate_limited?(identifier)

    # Find user
    user = find_user(email: email, phone: phone, user_type: user_type)
    raise UserNotFoundError, 'User not found' unless user

    # Check if delivery method is enabled
    raise DeliveryDisabledError, "#{delivery_method.upcase} delivery is not enabled" unless delivery_enabled?(delivery_method, user)

    # Create reset token
    token_record, raw_token = PasswordResetToken.create_for_user(
      user: user,
      user_type: determine_user_type(user, user_type),
      identifier: identifier,
      delivery_method: delivery_method,
      ip_address: @ip_address,
      user_agent: @user_agent
    )

    # Send reset instructions
    if delivery_method == 'email'
      send_email_reset(user, raw_token, identifier)
    else
      send_sms_reset(user, raw_token, identifier)
    end

    # Log the attempt
    log_reset_attempt(user, delivery_method, 'success')

    {
      success: true,
      message: 'Reset instructions sent successfully',
      delivery_method: delivery_method
    }
  rescue RateLimitError => e
    log_reset_attempt(nil, delivery_method, 'rate_limited', identifier)
    raise
  rescue UserNotFoundError => e
    log_reset_attempt(nil, delivery_method, 'user_not_found', identifier)
    # Don't reveal that user doesn't exist for security
    {
      success: true,
      message: 'Reset instructions sent successfully',
      delivery_method: delivery_method
    }
  rescue DeliveryDisabledError => e
    log_reset_attempt(user, delivery_method, 'delivery_disabled', identifier)
    raise
  rescue StandardError => e
    log_reset_attempt(user, delivery_method, 'error', identifier, e.message)
    raise DeliveryFailedError, 'Failed to send reset instructions'
  end

  def verify_token(token:)
    token_record = PasswordResetToken.find_valid_token(token)

    if token_record.nil?
      return {
        valid: false,
        message: 'Invalid or expired reset token'
      }
    end

    {
      valid: true,
      user_type: token_record.user_type,
      identifier: token_record.identifier,
      expires_at: token_record.expires_at
    }
  end

  def reset_password(token:, new_password:)
    token_record = PasswordResetToken.find_valid_token(token)

    raise UserNotFoundError, 'Invalid or expired reset token' unless token_record

    user = find_user_by_token(token_record)
    raise UserNotFoundError, 'User not found' unless user

    # Update password
    if user.is_a?(BuyerPortalAccess)
      user.update!(password: new_password)
    else
      user.update!(password: new_password)
    end

    # Mark token as used
    token_record.mark_as_used!

    # Log the reset
    log_password_reset(user, token_record.user_type)

    {
      success: true,
      message: 'Password has been reset successfully'
    }
  rescue StandardError => e
    Rails.logger.error("Password reset error: #{e.message}")
    raise
  end

  private

  def find_user(email:, phone:, user_type:)
    # Normalize phone if provided
    phone = PhoneNumberService.normalize(phone) if phone.present?
    
    if user_type == 'auto'
      # Check both tables by email or phone
      if email
        user = User.find_by(email: email.downcase)
        user ||= BuyerPortalAccess.find_by(email: email.downcase)
      elsif phone
        # Try multiple phone formats for flexibility
        user = find_user_by_phone(phone, ['admin', 'super_admin'])
        unless user
          # For BuyerPortalAccess, check the associated Contact's phone
          user = find_client_by_phone(phone)
        end
      end
      user
    elsif user_type == 'admin'
      if email
        User.where(role: ['admin', 'super_admin']).find_by(email: email.downcase)
      elsif phone
        find_user_by_phone(phone, ['admin', 'super_admin'])
      end
    elsif user_type == 'client'
      if email
        BuyerPortalAccess.find_by(email: email.downcase)
      elsif phone
        find_client_by_phone(phone)
      end
    end
  end

  def find_user_by_token(token_record)
    if token_record.user_type == 'admin'
      User.find_by(id: token_record.user_id)
    else
      BuyerPortalAccess.find_by(id: token_record.user_id)
    end
  end

  def find_user_by_phone(phone, roles = nil)
    # Try exact match first
    query = User.where(phone: phone)
    query = query.where(role: roles) if roles.present?
    user = query.first
    return user if user

    # Try without country code (e.g., if phone is +13035709810, try 3035709810)
    digits = PhoneNumberService.digits_only(phone)
    if digits.present?
      query = User.where("phone LIKE ?", "%#{digits}")
      query = query.where(role: roles) if roles.present?
      user = query.first
    end
    
    user
  end

  def find_client_by_phone(phone)
    # Try exact match first
    buyer_access = BuyerPortalAccess.joins(
      "INNER JOIN contacts ON buyer_portal_accesses.buyer_type = 'Contact' " \
      "AND buyer_portal_accesses.buyer_id = contacts.id"
    ).where(contacts: { phone: phone }).first
    
    return buyer_access if buyer_access
    
    # Try without country code formatting
    digits = PhoneNumberService.digits_only(phone)
    if digits.present?
      buyer_access = BuyerPortalAccess.joins(
        "INNER JOIN contacts ON buyer_portal_accesses.buyer_type = 'Contact' " \
        "AND buyer_portal_accesses.buyer_id = contacts.id"
      ).where("contacts.phone LIKE ?", "%#{digits}").first
    end
    
    buyer_access
  end

  def determine_user_type(user, requested_type)
    return requested_type unless requested_type == 'auto'

    if user.is_a?(User) && (user.admin? || user.role.in?(['admin', 'super_admin']))
      'admin'
    else
      'client'
    end
  end

  def rate_limited?(identifier)
    # Check how many attempts in the last hour
    count = PasswordResetToken
            .where(identifier: identifier)
            .where('created_at > ?', 1.hour.ago)
            .count

    count >= 5
  end

  def delivery_enabled?(delivery_method, user)
    # Get company if user has one
    company = if user.respond_to?(:company)
                user.company
              elsif user.is_a?(BuyerPortalAccess) && user.buyer.respond_to?(:company)
                user.buyer.company
              end

    # Check company settings first (if available), then platform settings
    if company
      company_enabled = check_company_delivery_settings(delivery_method, company)
      return company_enabled unless company_enabled.nil?
    end

    # Fall back to platform settings
    check_platform_delivery_settings(delivery_method)
  end

  def check_company_delivery_settings(delivery_method, company)
    # Get company communications settings
    settings = get_company_settings(company)
    return nil unless settings

    channel_settings = settings.dig('communications', delivery_method.to_s)
    return nil unless channel_settings

    # Check if enabled
    is_enabled = channel_settings['isEnabled']
    is_enabled == true || is_enabled == 'true'
  end

  def check_platform_delivery_settings(delivery_method)
    # Get platform communications settings
    settings = get_platform_settings
    return true unless settings # Default to enabled if no settings

    channel_settings = settings.dig('communications', delivery_method.to_s)
    return true unless channel_settings # Default to enabled if channel not configured

    # Check if enabled
    is_enabled = channel_settings['isEnabled']
    return true if is_enabled.nil? # Default to enabled if not explicitly set
    
    is_enabled == true || is_enabled == 'true'
  end

  def get_company_settings(company)
    # Try to get from company record first
    if company.respond_to?(:communications_settings)
      return company.communications_settings if company.communications_settings.present?
    end

    # Fall back to Settings table
    Setting.get('Company', company.id, 'communications')
  rescue StandardError => e
    Rails.logger.warn("Failed to get company settings: #{e.message}")
    nil
  end

  def get_platform_settings
    Setting.get('Platform', 0, 'communications')
  rescue StandardError => e
    Rails.logger.warn("Failed to get platform settings: #{e.message}")
    nil
  end

  def send_email_reset(user, token, email)
    reset_url = generate_reset_url(token)

    # Get email settings from platform/company
    email_settings = get_email_settings(user)

    PasswordResetMailer.reset_instructions(
      email: email,
      token: token,
      reset_url: reset_url,
      user_name: extract_user_name(user),
      email_settings: email_settings
    ).deliver_now
  end

  def send_sms_reset(user, code, phone)
    message = "Your password reset code is: #{code}\nValid for 15 minutes."

    # Get SMS settings from platform/company
    sms_settings = get_sms_settings(user)

    # Use SMS service with settings
    SmsService.new(sms_settings).send_message(
      to: phone,
      body: message
    )
  rescue StandardError => e
    Rails.logger.error("SMS send failed: #{e.message}")
    raise DeliveryFailedError, 'Failed to send SMS'
  end

  def get_email_settings(user)
    # Try company settings first (HIGHEST PRIORITY)
    company = extract_company(user)
    if company
      company_settings = get_company_settings(company)
      if company_settings && company_settings.dig('email', 'isEnabled')
        Rails.logger.info("✅ Using Company email settings for company_id=#{company.id}")
        settings = decrypt_settings(company_settings['email'])
        configure_action_mailer_smtp(settings)
        return settings
      end
    end

    # Fall back to platform settings (SECOND PRIORITY)
    platform_settings = get_platform_settings
    if platform_settings && platform_settings.dig('email', 'isEnabled')
      Rails.logger.info("✅ Using Platform email settings")
      settings = decrypt_settings(platform_settings['email'])
      configure_action_mailer_smtp(settings)
      return settings
    end

    # Ultimate fallback to ENV (LAST RESORT)
    Rails.logger.warn("⚠️  Using ENV fallback for email settings")
    {
      'provider' => ENV['EMAIL_PROVIDER'] || 'smtp',
      'fromEmail' => ENV['MAILER_FROM'] || 'noreply@renterinsight.com',
      'fromName' => ENV['EMAIL_FROM_NAME'] || 'RenterInsight'
    }
  end

  def get_sms_settings(user)
    # Try company settings first (HIGHEST PRIORITY)
    company = extract_company(user)
    if company
      company_settings = get_company_settings(company)
      if company_settings && company_settings.dig('sms', 'isEnabled')
        Rails.logger.info("✅ Using Company SMS settings for company_id=#{company.id}")
        return decrypt_settings(company_settings['sms'])
      end
    end

    # Fall back to platform settings (SECOND PRIORITY)
    platform_settings = get_platform_settings
    if platform_settings && platform_settings.dig('sms', 'isEnabled')
      Rails.logger.info("✅ Using Platform SMS settings")
      return decrypt_settings(platform_settings['sms'])
    end

    # Ultimate fallback to ENV (LAST RESORT)
    Rails.logger.warn("⚠️  Using ENV fallback for SMS settings")
    {
      'provider' => ENV['SMS_PROVIDER'] || 'twilio',
      'twilioAccountSid' => ENV['TWILIO_ACCOUNT_SID'],
      'twilioAuthToken' => ENV['TWILIO_AUTH_TOKEN'],
      'fromNumber' => ENV['TWILIO_PHONE_NUMBER']
    }
  end

  def extract_company(user)
    return user.company if user.respond_to?(:company) && user.company
    return user.buyer.company if user.is_a?(BuyerPortalAccess) && user.buyer.respond_to?(:company)
    nil
  end

  def decrypt_settings(settings)
    decrypted = settings.deep_dup
    
    # Decrypt sensitive fields
    decrypted.each do |key, value|
      if value.is_a?(String) && value.start_with?('encrypted:')
        decrypted[key] = decrypt(value)
      end
    end
    
    decrypted
  end

  def decrypt(encrypted_value)
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

  def generate_reset_url(token)
    # Get frontend URL from ENV or default
    frontend_url = ENV['FRONTEND_URL'] || 'http://localhost:5173'
    "#{frontend_url}/reset-password?token=#{token}"
  end

  def extract_user_name(user)
    if user.respond_to?(:first_name) && user.first_name.present?
      user.first_name
    elsif user.respond_to?(:name) && user.name.present?
      user.name
    elsif user.respond_to?(:email)
      user.email.split('@').first.capitalize
    else
      'User'
    end
  end

  def log_reset_attempt(user, delivery_method, status, identifier = nil, error_message = nil)
    Rails.logger.info({
      event: 'password_reset_attempt',
      user_id: user&.id,
      user_type: user&.class&.name,
      identifier: identifier || (user.respond_to?(:email) ? user.email : nil),
      delivery_method: delivery_method,
      status: status,
      ip_address: @ip_address,
      user_agent: @user_agent,
      error: error_message,
      timestamp: Time.current
    }.to_json)
  end

  def log_password_reset(user, user_type)
    Rails.logger.info({
      event: 'password_reset_completed',
      user_id: user.id,
      user_type: user_type,
      ip_address: @ip_address,
      timestamp: Time.current
    }.to_json)
  end

  def configure_action_mailer_smtp(email_settings)
    return unless email_settings['provider'] == 'smtp'

    smtp_config = {
      address: email_settings['smtpHost'] || 'smtp.gmail.com',
      port: (email_settings['smtpPort'] || 587).to_i,
      user_name: email_settings['smtpUsername'],
      password: email_settings['smtpPassword'],
      authentication: email_settings['smtpAuthentication'] || 'plain',
      enable_starttls_auto: email_settings['smtpEnableStarttls'].nil? ? true : email_settings['smtpEnableStarttls']
    }

    ActionMailer::Base.delivery_method = :smtp
    ActionMailer::Base.smtp_settings = smtp_config
    ActionMailer::Base.perform_deliveries = true
    ActionMailer::Base.raise_delivery_errors = true
    
    Rails.logger.info("📧 ActionMailer SMTP configured: #{email_settings['smtpHost']}:#{email_settings['smtpPort']} (user: #{email_settings['smtpUsername']})")
  rescue StandardError => e
    Rails.logger.error("❌ Failed to configure ActionMailer: #{e.message}")
    Rails.logger.error(e.backtrace.first(5).join("\n"))
  end
end
