class CommunicationSettingsService
  attr_reader :company
  
  def initialize(company: nil)
    @company = company
  end
  
  def self.for_company(company)
    new(company: company)
  end
  
  def self.platform
    new
  end
  
  def email_config
    config = merged_settings.dig('email') || {}
    
    {
      provider: config['provider'] || ENV['DEFAULT_EMAIL_PROVIDER'] || 'smtp',
      from_email: config['fromEmail'] || ENV['DEFAULT_FROM_EMAIL'] || 'noreply@platformdms.com',
      from_name: config['fromName'] || ENV['DEFAULT_FROM_NAME'] || 'Platform DMS',
      smtp_host: config['smtpHost'] || ENV['SMTP_ADDRESS'],
      smtp_port: (config['smtpPort'] || ENV['SMTP_PORT'] || 587).to_i,
      smtp_username: config['smtpUsername'] || ENV['SMTP_USERNAME'],
      smtp_password: decrypt_value(config['smtpPassword']) || ENV['SMTP_PASSWORD'],
      smtp_domain: config['smtpDomain'] || ENV['SMTP_DOMAIN'],
      smtp_authentication: config['smtpAuthentication'] || ENV['SMTP_AUTHENTICATION'] || 'plain',
      enabled: config['isEnabled'] != false
    }
  end
  
  def sms_config
    config = merged_settings.dig('sms') || {}
    
    {
      provider: config['provider'] || ENV['SMS_PROVIDER'] || 'twilio',
      from_number: config['fromNumber'] || ENV['TWILIO_PHONE_NUMBER'],
      twilio_account_sid: decrypt_value(config['twilioAccountSid']) || ENV['TWILIO_ACCOUNT_SID'],
      twilio_auth_token: decrypt_value(config['twilioAuthToken']) || ENV['TWILIO_AUTH_TOKEN'],
      enabled: config['isEnabled'] != false
    }
  end
  
  private
  
  # NEW METHOD: Intelligently merge Company + Platform settings
  # Company settings override Platform, but missing/blank fields use Platform defaults
  def merged_settings
    return @merged_settings if defined?(@merged_settings)
    
    # Always load platform settings as the base
    platform_setting = Setting.find_by(key: 'communications', scope_type: 'Platform', scope_id: 0)
    platform_data = if platform_setting&.value.present?
                      platform_setting.value.is_a?(Hash) ? platform_setting.value : JSON.parse(platform_setting.value)
                    else
                      {}
                    end
    
    # If no company, just use platform settings
    unless company
      @merged_settings = platform_data
      return @merged_settings
    end
    
    # Load company settings
    company_setting = Setting.find_by(key: 'communications', scope_type: 'Company', scope_id: company.id)
    company_data = if company_setting&.value.present?
                     company_setting.value.is_a?(Hash) ? company_setting.value : JSON.parse(company_setting.value)
                   else
                     {}
                   end
    
    # Deep merge: Company overrides Platform, but blank/nil company fields use platform values
    @merged_settings = deep_merge_settings(platform_data, company_data)
    
    Rails.logger.debug("📧 Merged settings for company_id=#{company.id}: email.fromEmail=#{@merged_settings.dig('email', 'fromEmail')}, sms.fromNumber=#{@merged_settings.dig('sms', 'fromNumber')}")
    
    @merged_settings
  rescue JSON::ParserError => e
    Rails.logger.error("Failed to parse communication settings: #{e.message}")
    {}
  rescue StandardError => e
    Rails.logger.error("Failed to merge communication settings: #{e.message}")
    platform_data || {}
  end
  
  # Deep merge helper: recursively merges hashes, with override taking precedence
  # CRITICAL: Only merges non-blank values from override (treats "" same as nil)
  def deep_merge_settings(base, override)
    result = base.deep_dup
    
    override.each do |key, value|
      if value.is_a?(Hash) && result[key].is_a?(Hash)
        # Recursively merge nested hashes
        result[key] = deep_merge_settings(result[key], value)
      elsif value.present? # This checks for non-nil AND non-blank (excludes "", [], {})
        # Override with non-blank values only
        result[key] = value
      end
      # If value is nil or blank, skip it and keep base value
    end
    
    result
  end
  
  # DEPRECATED: Keep for backwards compatibility, but now just delegates to merged_settings
  def communication_settings
    merged_settings
  end
  
  def decrypt_value(value)
    return nil if value.blank?
    return value unless value.is_a?(String) && value.start_with?('encrypted:')
    
    # Use same encryption method as password_reset_service.rb
    encrypted_data = value.sub('encrypted:', '')
    secret_key = ENV['SETTINGS_ENCRYPTION_KEY'] || Rails.application.secret_key_base
    key = ActiveSupport::KeyGenerator.new(secret_key).generate_key('', 32)
    crypt = ActiveSupport::MessageEncryptor.new(key)
    
    crypt.decrypt_and_verify(encrypted_data)
  rescue StandardError => e
    Rails.logger.error("Failed to decrypt communication setting: #{e.message}")
    nil
  end
end
