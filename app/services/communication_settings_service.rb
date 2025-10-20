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
    config = communication_settings.dig('email') || {}
    
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
    config = communication_settings.dig('sms') || {}
    
    {
      provider: config['provider'] || ENV['SMS_PROVIDER'] || 'twilio',
      from_number: config['fromNumber'] || ENV['TWILIO_PHONE_NUMBER'],
      twilio_account_sid: decrypt_value(config['twilioAccountSid']) || ENV['TWILIO_ACCOUNT_SID'],
      twilio_auth_token: decrypt_value(config['twilioAuthToken']) || ENV['TWILIO_AUTH_TOKEN'],
      enabled: config['isEnabled'] != false
    }
  end
  
  private
  
  def communication_settings
    return @communication_settings if defined?(@communication_settings)
    
    setting = nil
    
    if company
      setting = Setting.find_by(key: 'communications', scope_type: 'Company', scope_id: company.id)
    end
    
    setting ||= Setting.find_by(key: 'communications', scope_type: ['Platform', nil])
    
    @communication_settings = setting&.value.present? ? JSON.parse(setting.value) : {}
  rescue JSON::ParserError
    {}
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
