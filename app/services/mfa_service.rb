# frozen_string_literal: true

class MfaService
  class RateLimitError < StandardError; end
  class DeliveryDisabledError < StandardError; end
  class DeliveryFailedError < StandardError; end
  class InvalidCodeError < StandardError; end

  def initialize(ip_address: nil, user_agent: nil)
    @ip_address = ip_address
    @user_agent = user_agent
  end

  # Request MFA code for login verification
  def request_code(user:, user_type:, delivery_method:)
    # Rate limiting check (max 3 codes per 15 minutes)
    if MfaToken.rate_limited?(user: user, user_type: user_type)
      raise RateLimitError, 'Too many MFA requests. Please try again in 15 minutes.'
    end

    # Determine identifier (email or phone)
    identifier = extract_identifier(user, delivery_method)
    raise DeliveryFailedError, 'No contact information available' if identifier.blank?

    # Check if delivery method is enabled
    unless delivery_enabled?(delivery_method, user)
      raise DeliveryDisabledError, "#{delivery_method.upcase} delivery is not enabled"
    end

    # Create MFA token
    token_record, raw_code = MfaToken.create_for_user(
      user: user,
      user_type: user_type,
      identifier: identifier,
      delivery_method: delivery_method,
      ip_address: @ip_address,
      user_agent: @user_agent
    )

    # Send the code
    if delivery_method == 'email'
      send_email_code(user, raw_code, identifier, user_type)
    else
      send_sms_code(user, raw_code, identifier)
    end

    # Log the attempt
    log_mfa_request(user, delivery_method, 'success')

    {
      success: true,
      message: 'Verification code sent successfully',
      delivery_method: delivery_method,
      identifier: mask_identifier(identifier, delivery_method),
      expires_in: 300 # 5 minutes in seconds
    }
  rescue RateLimitError => e
    log_mfa_request(user, delivery_method, 'rate_limited')
    raise
  rescue DeliveryDisabledError => e
    log_mfa_request(user, delivery_method, 'delivery_disabled')
    raise
  rescue StandardError => e
    Rails.logger.error("MFA code request error: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    log_mfa_request(user, delivery_method, 'error', e.message)
    raise DeliveryFailedError, 'Failed to send verification code'
  end

  # Verify MFA code
  def verify_code(user:, user_type:, code:)
    # Find valid token
    token_record = MfaToken.find_valid_token(code)

    if token_record.nil?
      log_mfa_verification(user, user_type, 'invalid_code')
      raise InvalidCodeError, 'Invalid or expired verification code'
    end

    # Verify token belongs to this user
    unless token_record.user_id == user.id && token_record.user_type == user_type
      log_mfa_verification(user, user_type, 'user_mismatch')
      raise InvalidCodeError, 'Invalid verification code'
    end

    # Check if too many failed attempts
    if token_record.attempts >= 5
      log_mfa_verification(user, user_type, 'too_many_attempts')
      raise InvalidCodeError, 'Too many failed attempts. Please request a new code.'
    end

    # Check if token is still valid
    unless token_record.valid_for_verification?
      token_record.increment_attempts!
      log_mfa_verification(user, user_type, 'expired')
      raise InvalidCodeError, 'Verification code has expired. Please request a new code.'
    end

    # Mark token as used
    token_record.mark_as_used!

    # Log successful verification
    log_mfa_verification(user, user_type, 'success')

    {
      success: true,
      message: 'Verification successful'
    }
  rescue InvalidCodeError => e
    # Increment attempts if token exists and is valid
    token_record&.increment_attempts! if token_record&.valid_for_verification?
    raise
  rescue StandardError => e
    Rails.logger.error("MFA verification error: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    raise InvalidCodeError, 'Verification failed'
  end

  private

  def extract_identifier(user, delivery_method)
    if delivery_method == 'email'
      user.email
    else
      # For SMS, try to get phone from user or associated contact
      phone = if user.respond_to?(:phone)
                user.phone
              elsif user.is_a?(BuyerPortalAccess) && user.buyer.respond_to?(:phone)
                user.buyer.phone
              end
      
      # Normalize phone number
      PhoneNumberService.normalize(phone) if phone.present?
    end
  end

  def extract_company(user)
    return user.company if user.respond_to?(:company) && user.company
    return user.buyer.company if user.is_a?(BuyerPortalAccess) && user.buyer.respond_to?(:company)
    nil
  end

  def delivery_enabled?(delivery_method, user)
    # Get company if user has one
    company = extract_company(user)

    # Check company settings first (if available)
    if company
      company_enabled = check_company_delivery_settings(delivery_method, company)
      return company_enabled unless company_enabled.nil?
    end

    # Fall back to platform settings
    check_platform_delivery_settings(delivery_method)
  end

  def check_company_delivery_settings(delivery_method, company)
    settings = get_company_settings(company)
    return nil unless settings

    channel_settings = settings.dig('communications', delivery_method.to_s)
    return nil unless channel_settings

    is_enabled = channel_settings['isEnabled']
    is_enabled == true || is_enabled == 'true'
  end

  def check_platform_delivery_settings(delivery_method)
    settings = get_platform_settings
    return true unless settings

    channel_settings = settings.dig('communications', delivery_method.to_s)
    return true unless channel_settings

    is_enabled = channel_settings['isEnabled']
    return true if is_enabled.nil?
    
    is_enabled == true || is_enabled == 'true'
  end

  def get_company_settings(company)
    if company.respond_to?(:communications_settings)
      return company.communications_settings if company.communications_settings.present?
    end

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

  def send_email_code(user, code, email, user_type)
    # Get email settings (follows Platform → Company → Location waterfall)
    email_settings = get_email_settings(user)

    MfaMailer.verification_code(
      email: email,
      code: code,
      user_name: extract_user_name(user),
      email_settings: email_settings
    ).deliver_now

    Rails.logger.info "📧 MFA email sent to #{email}"
  end

  def send_sms_code(user, code, phone)
    message = "Your verification code is: #{code}\nValid for 5 minutes."

    result = TwilioSmsService.send_via_master(to: phone, body: message)

    unless result[:success]
      raise DeliveryFailedError, result[:error] || 'Failed to send SMS'
    end

    Rails.logger.info "[MfaService] MFA SMS sent to #{phone}: #{result[:message_sid]}"
  end

  def get_email_settings(user)
    # Try company settings first
    company = extract_company(user)
    if company
      company_settings = get_company_settings(company)
      if company_settings && company_settings.dig('email', 'isEnabled')
        return decrypt_settings(company_settings['email'])
      end
    end

    # Fall back to platform settings
    platform_settings = get_platform_settings
    if platform_settings && platform_settings.dig('email', 'isEnabled')
      return decrypt_settings(platform_settings['email'])
    end

    # Ultimate fallback to ENV
    {
      'provider' => ENV['EMAIL_PROVIDER'] || 'smtp',
      'fromEmail' => ENV['MAILER_FROM'] || Brand.from_email,
      'fromName' => ENV['EMAIL_FROM_NAME'] || Brand.from_name
    }
  end

  def get_sms_settings(user)
    # Try company settings first
    company = extract_company(user)
    if company
      company_settings = get_company_settings(company)
      if company_settings && company_settings.dig('sms', 'isEnabled')
        return decrypt_settings(company_settings['sms'])
      end
    end

    # Fall back to platform settings
    platform_settings = get_platform_settings
    if platform_settings && platform_settings.dig('sms', 'isEnabled')
      return decrypt_settings(platform_settings['sms'])
    end

    # Ultimate fallback to ENV
    {
      'provider' => ENV['SMS_PROVIDER'] || 'twilio',
      'twilioAccountSid' => ENV['TWILIO_ACCOUNT_SID'],
      'twilioAuthToken' => ENV['TWILIO_AUTH_TOKEN'],
      'fromNumber' => ENV['TWILIO_PHONE_NUMBER']
    }
  end

  def decrypt_settings(settings)
    decrypted = settings.deep_dup
    
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

  def mask_identifier(identifier, delivery_method)
    return '' if identifier.blank?

    if delivery_method == 'email'
      # Mask email: t***@example.com
      local, domain = identifier.split('@')
      return identifier if domain.nil?
      "#{local[0]}***@#{domain}"
    else
      # Mask phone: ***-***-1234
      digits = identifier.gsub(/\D/, '')
      return identifier if digits.length < 4
      "***-***-#{digits[-4..-1]}"
    end
  end

  def log_mfa_request(user, delivery_method, status, error_message = nil)
    Rails.logger.info({
      event: 'mfa_code_request',
      user_id: user&.id,
      user_type: user&.class&.name,
      delivery_method: delivery_method,
      status: status,
      ip_address: @ip_address,
      user_agent: @user_agent,
      error: error_message,
      timestamp: Time.current
    }.to_json)
  end

  def log_mfa_verification(user, user_type, status, error_message = nil)
    Rails.logger.info({
      event: 'mfa_verification',
      user_id: user&.id,
      user_type: user_type,
      status: status,
      ip_address: @ip_address,
      timestamp: Time.current,
      error: error_message
    }.to_json)
  end
end
