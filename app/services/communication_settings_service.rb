class CommunicationSettingsService
  attr_reader :company, :location, :user
  
  def initialize(company: nil, location: nil, user: nil)
    @company = company
    @location = location
    @user = user
  end
  
  def self.for_company(company, location: nil)
    new(company: company, location: location)
  end
  
  # NEW: Include user-level email connection in waterfall
  def self.for_user(user, location: nil)
    new(company: user&.company, location: location, user: user)
  end
  
  def self.platform
    new
  end
  
  # UPDATED WATERFALL: User → Location → Company → Platform
  # User email connection has highest priority (if configured and verified)
  def email_config
    # Check for user-level email connection first
    if user&.has_email_connection?
      user_connection = user.default_email_connection
      if user_connection&.verified? && user_connection.is_active
        return user_email_config(user_connection)
      end
    end
    
    # Fall back to standard waterfall: Location → Company → Platform
    config = merged_settings.dig('email') || {}

    # Handle OAuth providers - use SMTP with XOAUTH2 authentication
    provider_value = config['provider'] || config[:provider]
    if provider_value.to_s.start_with?('oauth_')
      oauth_email    = config['oauthEmail'] || config[:oauthEmail]
      oauth_provider = config['oauthProvider'] || config[:oauthProvider]
      access_token   = refresh_oauth_token_if_needed(config)
      smtp_host, smtp_port = oauth_smtp_host_port(oauth_provider)

      return {
        provider: provider_value,
        from_email: oauth_email || config['fromEmail'] || config[:fromEmail],
        from_name: config['fromName'] || config[:fromName] || oauth_email,
        smtp_host: smtp_host,
        smtp_port: smtp_port,
        smtp_username: oauth_email,
        smtp_password: access_token,
        smtp_authentication: 'xoauth2',
        enabled: (config['isEnabled'] || config[:isEnabled]) != false,
        source: determine_email_source
      }
    end

    {
      provider: config['provider'] || ENV['DEFAULT_EMAIL_PROVIDER'] || 'smtp',
      from_email: config['fromEmail'] || ENV['DEFAULT_FROM_EMAIL'] || 'noreply@platformdms.com',
      from_name: config['fromName'] || ENV['DEFAULT_FROM_NAME'] || 'Platform DMS',
      
      # SMTP fields
      smtp_host: config['smtpHost'] || ENV['SMTP_ADDRESS'],
      smtp_port: (config['smtpPort'] || ENV['SMTP_PORT'] || 587).to_i,
      smtp_username: config['smtpUsername'] || ENV['SMTP_USERNAME'],
      smtp_password: decrypt_value(config['smtpPassword']) || ENV['SMTP_PASSWORD'],
      smtp_domain: config['smtpDomain'] || ENV['SMTP_DOMAIN'],
      smtp_authentication: config['smtpAuthentication'] || ENV['SMTP_AUTHENTICATION'] || 'plain',
      
      # AWS SES fields
      aws_access_key_id: config['awsAccessKeyId'] || ENV['AWS_ACCESS_KEY_ID'],
      aws_secret_access_key: decrypt_value(config['awsSecretAccessKey']) || ENV['AWS_SECRET_ACCESS_KEY'],
      aws_region: config['awsRegion'] || ENV['AWS_REGION'] || 'us-east-1',
      
      # SendGrid fields
      sendgrid_api_key: decrypt_value(config['sendgridApiKey']) || ENV['SENDGRID_API_KEY'],
      
      enabled: config['isEnabled'] != false,
      
      # Metadata about source
      source: determine_email_source
    }
  end
  
  def sms_config
    # Phase 0: Check SMS provisioning mode before returning config
    mode = company&.sms_provisioning_mode || 'platform'
    
    if mode == 'disabled'
      Rails.logger.info "[CommunicationSettingsService] SMS disabled for company #{company&.id}"
      return {
        provider: 'twilio',
        from_number: nil,
        twilio_account_sid: nil,
        twilio_auth_token: nil,
        enabled: false,
        sms_provisioning_mode: 'disabled'
      }
    end
    
    # Phase 1: Dedicated number on master account
    # Numbers are now purchased on the master Twilio account directly (not sub-accounts),
    # so we use master credentials with the company's dedicated from_number.
    if mode == 'dedicated' && company&.twilio_account&.active?
      ta = company.twilio_account
      master_sid   = ENV['TWILIO_ACCOUNT_SID'].presence
      master_token = ENV['TWILIO_AUTH_TOKEN'].presence

      # Fall back to platform settings if env vars not set (local dev)
      unless master_sid && master_token
        sms_cfg = PlatformSetting.communications.dig(:sms) ||
                  PlatformSetting.communications.dig('sms') || {}
        master_sid   ||= sms_cfg[:twilioAccountSid].presence || sms_cfg['twilioAccountSid'].presence
        enc_token = sms_cfg[:twilioAuthToken].presence || sms_cfg['twilioAuthToken'].presence
        master_token ||= decrypt_value(enc_token)
      end

      # Messaging Service SID is the same for all companies (master A2P registration)
      msid = ENV['TWILIO_MESSAGING_SERVICE_SID'].presence ||
             begin
               sms_cfg = PlatformSetting.communications.dig(:sms) ||
                         PlatformSetting.communications.dig('sms') || {}
               sms_cfg[:twilioMessagingServiceSid].presence || sms_cfg['twilioMessagingServiceSid'].presence
             rescue StandardError
               nil
             end

      Rails.logger.info "[CommSettings] Using dedicated number on master Twilio for Company #{company.id}: #{ta.phone_number}"
      return {
        provider:                      'twilio',
        from_number:                   ta.phone_number,
        twilio_account_sid:            master_sid,
        twilio_auth_token:             master_token,
        twilio_messaging_service_sid:  msid,
        enabled:                       true,
        sms_provisioning_mode:         'dedicated',
        source:                        'dedicated_master_account'
      }
    end

    # For 'platform' mode: use existing waterfall
    config = merged_settings.dig('sms') || {}

    {
      provider:                      config['provider'] || ENV['SMS_PROVIDER'] || 'twilio',
      from_number:                   config['fromNumber'] || ENV['TWILIO_PHONE_NUMBER'],
      twilio_account_sid:            decrypt_value(config['twilioAccountSid']) || ENV['TWILIO_ACCOUNT_SID'],
      twilio_auth_token:             decrypt_value(config['twilioAuthToken']) || ENV['TWILIO_AUTH_TOKEN'],
      twilio_messaging_service_sid:  config['twilioMessagingServiceSid'] || ENV['TWILIO_MESSAGING_SERVICE_SID'],
      enabled:                       config['isEnabled'] != false,
      sms_provisioning_mode:         mode
    }
  end
  
  private
  
  # Build email config from user's personal email connection
  def user_email_config(connection)
    base_config = {
      from_email: connection.email_address,
      from_name: connection.display_name || user.name,
      enabled: true,
      source: 'user',
      user_connection_id: connection.id
    }
    
    case connection.provider
    when 'smtp'
      base_config.merge(
        provider: 'smtp',
        smtp_host: connection.smtp_host,
        smtp_port: connection.smtp_port || 587,
        smtp_username: connection.smtp_username,
        smtp_password: connection.smtp_password_encrypted,
        smtp_authentication: connection.smtp_authentication || 'plain',
        smtp_enable_starttls: connection.smtp_enable_starttls
      )
    when 'company_domain'
      # Use company's email infrastructure but with user's email as from
      company_config = merged_settings.dig('email') || {}
      base_config.merge(
        provider: company_config['provider'] || ENV['DEFAULT_EMAIL_PROVIDER'] || 'smtp',
        smtp_host: company_config['smtpHost'] || ENV['SMTP_ADDRESS'],
        smtp_port: (company_config['smtpPort'] || ENV['SMTP_PORT'] || 587).to_i,
        smtp_username: company_config['smtpUsername'] || ENV['SMTP_USERNAME'],
        smtp_password: decrypt_value(company_config['smtpPassword']) || ENV['SMTP_PASSWORD'],
        smtp_authentication: company_config['smtpAuthentication'] || ENV['SMTP_AUTHENTICATION'] || 'plain',
        aws_access_key_id: company_config['awsAccessKeyId'] || ENV['AWS_ACCESS_KEY_ID'],
        aws_secret_access_key: decrypt_value(company_config['awsSecretAccessKey']) || ENV['AWS_SECRET_ACCESS_KEY'],
        aws_region: company_config['awsRegion'] || ENV['AWS_REGION'] || 'us-east-1'
      )
    when 'oauth_gmail', 'oauth_outlook'
      oauth_provider = connection.oauth_provider
      oauth_config = {
        'oauthProvider' => oauth_provider,
        'oauthAccessToken' => connection.oauth_token_encrypted,
        'oauthRefreshToken' => connection.oauth_refresh_token_encrypted,
        'oauthExpiresAt' => connection.oauth_expires_at&.iso8601
      }
      access_token = refresh_oauth_token_if_needed(oauth_config, user_connection: connection)
      smtp_host, smtp_port = oauth_smtp_host_port(oauth_provider)

      base_config.merge(
        provider: connection.provider,
        smtp_host: smtp_host,
        smtp_port: smtp_port,
        smtp_username: connection.email_address,
        smtp_password: access_token,
        smtp_authentication: 'xoauth2'
      )
    else
      base_config
    end
  end
  
  # Determine where email settings are coming from
  def determine_email_source
    if user&.has_email_connection? && user.default_email_connection&.verified?
      'user'
    elsif location && Setting.exists?(key: 'communications', scope_type: 'Location', scope_id: location.id)
      'location'
    elsif company && Setting.exists?(key: 'communications', scope_type: 'Company', scope_id: company.id)
      'company'
    else
      'platform'
    end
  end
  
  # WATERFALL: Platform → Company → Location (Location has highest priority)
  def merged_settings
    return @merged_settings if defined?(@merged_settings)
    
    # Start with platform settings as the base
    platform_setting = Setting.find_by(key: 'communications', scope_type: 'Platform', scope_id: 0)
    platform_data = if platform_setting&.value.present?
                      platform_setting.value.is_a?(Hash) ? platform_setting.value : JSON.parse(platform_setting.value)
                    else
                      {}
                    end
    
    # Merge company settings (overrides platform)
    if company
      company_setting = Setting.find_by(key: 'communications', scope_type: 'Company', scope_id: company.id)
      company_data = if company_setting&.value.present?
                       company_setting.value.is_a?(Hash) ? company_setting.value : JSON.parse(company_setting.value)
                     else
                       {}
                     end
      platform_data = deep_merge_settings(platform_data, company_data)
    end
    
    # Merge location settings (overrides company, highest priority)
    if location
      location_setting = Setting.find_by(key: 'communications', scope_type: 'Location', scope_id: location.id)
      location_data = if location_setting&.value.present?
                        location_setting.value.is_a?(Hash) ? location_setting.value : JSON.parse(location_setting.value)
                      else
                        {}
                      end
      platform_data = deep_merge_settings(platform_data, location_data)
    end
    
    @merged_settings = platform_data
    
    # Debug logging
    scope_info = if user
                   "user_id=#{user.id}"
                 elsif location
                   "location_id=#{location.id}"
                 elsif company
                   "company_id=#{company.id}"
                 else
                   "platform"
                 end
    
    Rails.logger.debug("📧 Merged settings for #{scope_info}: email.fromEmail=#{@merged_settings.dig('email', 'fromEmail')}, sms.fromNumber=#{@merged_settings.dig('sms', 'fromNumber')}")
    
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
  
  # ----------------------------------------------------------------
  # OAuth token refresh
  # ----------------------------------------------------------------

  def oauth_smtp_host_port(provider)
    case provider.to_s
    when 'microsoft' then ['smtp.office365.com', 587]
    when 'google'    then ['smtp.gmail.com', 587]
    else ['smtp.gmail.com', 587]
    end
  end

  def refresh_oauth_token_if_needed(config, user_connection: nil)
    expires_at_str = config['oauthExpiresAt'] || config[:oauthExpiresAt]
    access_token   = config['oauthAccessToken'] || config[:oauthAccessToken]

    if expires_at_str.present?
      expires_at = Time.parse(expires_at_str.to_s) rescue nil
      if expires_at && expires_at <= 5.minutes.from_now
        refreshed = perform_oauth_token_refresh(config)
        if refreshed
          persist_refreshed_tokens(refreshed, config, user_connection: user_connection)
          return refreshed[:access_token]
        end
      end
    end

    access_token
  rescue => e
    Rails.logger.error "[CommunicationSettingsService] Token refresh check failed: #{e.message}"
    access_token
  end

  def perform_oauth_token_refresh(config)
    provider      = config['oauthProvider'] || config[:oauthProvider]
    refresh_token = config['oauthRefreshToken'] || config[:oauthRefreshToken]
    return nil if refresh_token.blank?

    token_url = case provider
                when 'microsoft' then 'https://login.microsoftonline.com/common/oauth2/v2.0/token'
                when 'google'    then 'https://oauth2.googleapis.com/token'
                else return nil
                end

    client_id     = Rails.application.credentials.dig(:oauth, provider.to_sym, :client_id)
    client_secret = Rails.application.credentials.dig(:oauth, provider.to_sym, :client_secret)

    uri = URI(token_url)
    req = Net::HTTP::Post.new(uri)
    req.set_form_data(
      client_id:     client_id,
      client_secret: client_secret,
      refresh_token: refresh_token,
      grant_type:    'refresh_token'
    )
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
    tokens = JSON.parse(res.body)

    if tokens['error'].present?
      Rails.logger.error "[CommunicationSettingsService] OAuth refresh error: #{tokens['error_description'] || tokens['error']}"
      return nil
    end

    {
      access_token:  tokens['access_token'],
      refresh_token: tokens['refresh_token'].presence || refresh_token,
      expires_at:    (Time.current + tokens['expires_in'].to_i.seconds).iso8601
    }
  rescue => e
    Rails.logger.error "[CommunicationSettingsService] OAuth token refresh failed: #{e.message}"
    nil
  end

  def persist_refreshed_tokens(refreshed, _config, user_connection: nil)
    if user_connection
      user_connection.update!(
        oauth_token_encrypted:         refreshed[:access_token],
        oauth_refresh_token_encrypted: refreshed[:refresh_token],
        oauth_expires_at:              Time.parse(refreshed[:expires_at])
      )
      return
    end

    scope_class, scope_id = find_oauth_settings_scope
    return unless scope_class

    existing       = Setting.get(scope_class, scope_id, 'communications') || {}
    existing_email = (existing['email'] || {}).stringify_keys
    merged_email   = existing_email.merge(
      'oauthAccessToken'  => refreshed[:access_token],
      'oauthRefreshToken' => refreshed[:refresh_token],
      'oauthExpiresAt'    => refreshed[:expires_at]
    )
    merged_comms = existing.stringify_keys.merge('email' => merged_email)
    Setting.set(scope_class, scope_id, 'communications', merged_comms)
  rescue => e
    Rails.logger.error "[CommunicationSettingsService] Failed to persist refreshed tokens: #{e.message}"
  end

  def find_oauth_settings_scope
    if location
      loc = Setting.get('Location', location.id, 'communications')
      return ['Location', location.id] if loc.is_a?(Hash) && loc.dig('email', 'oauthProvider').present?
    end

    if company
      comp = Setting.get('Company', company.id, 'communications')
      return ['Company', company.id] if comp.is_a?(Hash) && comp.dig('email', 'oauthProvider').present?
    end

    plat = Setting.get('Platform', 0, 'communications')
    return ['Platform', 0] if plat.is_a?(Hash) && plat.dig('email', 'oauthProvider').present?

    nil
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
