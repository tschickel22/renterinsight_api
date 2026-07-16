# frozen_string_literal: true

# QuickBooks Integration Concern
# Provides common methods for QuickBooks integration
# Include in Company and Location models

module QuickbooksIntegration
  extend ActiveSupport::Concern
  
  # Get access token (handles encryption)
  def quickbooks_access_token
    encrypted = if respond_to?(:quickbooks_access_token_encrypted)
      read_attribute(:quickbooks_access_token_encrypted)
    else
      read_attribute(:quickbooks_access_token)
    end
    
    return nil unless encrypted.present?
    
    # Decrypt if it looks encrypted (has double hyphens from MessageEncryptor)
    if encrypted.include?('--')
      begin
        crypt = ActiveSupport::MessageEncryptor.new(Rails.application.key_generator.generate_key('quickbooks_tokens', 32))
        crypt.decrypt_and_verify(encrypted)
      rescue => e
        Rails.logger.error "Failed to decrypt QB access token: #{e.message}"
        nil
      end
    else
      # Plain text token (legacy)
      encrypted
    end
  end
  
  # Get refresh token (handles encryption)
  def quickbooks_refresh_token
    encrypted = if respond_to?(:quickbooks_refresh_token_encrypted)
      read_attribute(:quickbooks_refresh_token_encrypted)
    else
      read_attribute(:quickbooks_refresh_token)
    end
    
    return nil unless encrypted.present?
    
    # Decrypt if it looks encrypted (has double hyphens from MessageEncryptor)
    if encrypted.include?('--')
      begin
        crypt = ActiveSupport::MessageEncryptor.new(Rails.application.key_generator.generate_key('quickbooks_tokens', 32))
        crypt.decrypt_and_verify(encrypted)
      rescue => e
        Rails.logger.error "Failed to decrypt QB refresh token: #{e.message}"
        nil
      end
    else
      # Plain text token (legacy)
      encrypted
    end
  end
  
  # Check if connected to QuickBooks
  def quickbooks_connected?
    # CRITICAL: Use decryption methods, not encrypted attributes directly
    quickbooks_access_token.present? && quickbooks_realm_id.present?
  end
  
  # Check if access token has expired
  def quickbooks_token_expired?
    return true unless quickbooks_token_expires_at.present?
    
    # Consider token expired if less than 5 minutes remaining
    quickbooks_token_expires_at < 5.minutes.from_now
  end
  
  # Advisory-lock namespace for QB token refresh — distinct from other
  # accounting number-generator namespaces.
  QB_TOKEN_REFRESH_LOCK_NAMESPACE = 0x1_2E_00_71.freeze

  # Refresh QuickBooks access token using refresh token. Serialized via a
  # per-entity advisory lock so two concurrent syncs can't both burn a
  # refresh_token grant. If another process refreshed while we waited on
  # the lock, we short-circuit and return the just-refreshed state.
  def refresh_quickbooks_token!
    ApplicationRecord.transaction do
      self.class.connection.execute(
        self.class.sanitize_sql_array([
          'SELECT pg_advisory_xact_lock(?, ?)',
          QB_TOKEN_REFRESH_LOCK_NAMESPACE,
          id
        ])
      )
      reload
      unless quickbooks_token_expired?
        return { success: true, expires_at: quickbooks_token_expires_at, note: 'refreshed by another process while waiting on lock' }
      end
      _do_refresh_quickbooks_token!
    end
  end

  # Internal — the actual HTTP call and DB writes. Callers should go through
  # refresh_quickbooks_token! so the advisory lock guarantees serialization.
  def _do_refresh_quickbooks_token!
    # CRITICAL: Use decryption method, not encrypted attribute directly
    current_refresh_token = quickbooks_refresh_token

    return { success: false, error: 'No refresh token' } unless current_refresh_token.present?

    begin
      # QuickBooks token endpoint
      token_url = 'https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer'
      
      # Prepare credentials - use ENV vars first (for production), fallback to Rails credentials (for local dev)
      client_id = ENV['QUICKBOOKS_CLIENT_ID'] || Rails.application.credentials.dig(:quickbooks, :client_id)
      client_secret = ENV['QUICKBOOKS_CLIENT_SECRET'] || Rails.application.credentials.dig(:quickbooks, :client_secret)
      
      Rails.logger.info "[QB Refresh] Refreshing QB token for #{self.class.name} ##{id}"
      Rails.logger.info "[QB Refresh] Client ID: #{client_id&.first(10)}..." if client_id
      Rails.logger.info "[QB Refresh] Has secret: #{client_secret.present?}"
      Rails.logger.info "[QB Refresh] Token URL: #{token_url}"
      
      unless client_id.present? && client_secret.present?
        error_msg = "QuickBooks credentials not configured. Set QUICKBOOKS_CLIENT_ID and QUICKBOOKS_CLIENT_SECRET environment variables."
        Rails.logger.error "[QB Refresh] #{error_msg}"
        return { success: false, error: error_msg }
      end
      
      # Make token refresh request
      response = HTTParty.post(token_url, {
        headers: {
          'Accept' => 'application/json',
          'Content-Type' => 'application/x-www-form-urlencoded',
          'Authorization' => "Basic #{Base64.strict_encode64("#{client_id}:#{client_secret}")}"
        },
        body: {
          grant_type: 'refresh_token',
          refresh_token: current_refresh_token
        }
      })
      
      Rails.logger.info "[QB Refresh] QB Refresh Response Code: #{response.code}"
      
      if response.code == 200
        data = response.parsed_response
        
        Rails.logger.info "[QB Refresh] QB Token refresh successful, new token expires in #{data['expires_in']} seconds"
        
        # Encrypt tokens using same method as OAuth service
        crypt = ActiveSupport::MessageEncryptor.new(Rails.application.key_generator.generate_key('quickbooks_tokens', 32))
        encrypted_access_token = crypt.encrypt_and_sign(data['access_token'])
        encrypted_refresh_token = crypt.encrypt_and_sign(data['refresh_token'])
        
        # Update tokens with ENCRYPTED values
        update_attrs = {
          quickbooks_access_token_encrypted: encrypted_access_token,
          quickbooks_refresh_token_encrypted: encrypted_refresh_token,
          quickbooks_token_expires_at: Time.current + data['expires_in'].seconds
        }
        
        if respond_to?(:quickbooks_refresh_token_expires_at=) && data['x_refresh_token_expires_in']
          update_attrs[:quickbooks_refresh_token_expires_at] = Time.current + data['x_refresh_token_expires_in'].seconds
        end
        
        # Save with validations skipped to avoid issues
        update!(update_attrs)
        
        Rails.logger.info "QuickBooks token refreshed successfully for #{self.class.name} ##{id}"
        
        { success: true, expires_at: quickbooks_token_expires_at }
      else
        error_msg = response.parsed_response['error_description'] || response.parsed_response['error'] || 'Token refresh failed'
        
        if error_msg.include?('invalid_client')
          error_msg = "Invalid QuickBooks credentials. The credentials configured in environment variables don't match the app that issued the original token. Please disconnect and reconnect QuickBooks."
        end
        
        Rails.logger.error "[QB Refresh] QuickBooks token refresh failed: #{error_msg}"
        Rails.logger.error "[QB Refresh] Response body: #{response.body}"
        
        { success: false, error: error_msg }
      end
      
    rescue => e
      Rails.logger.error "[QB Refresh] QuickBooks token refresh error: #{e.message}"
      Rails.logger.error "[QB Refresh] #{e.backtrace.first(5).join('\n')}"
      { success: false, error: e.message }
    end
  end
  
  # Get resolved QuickBooks settings (with inheritance for locations)
  def resolved_quickbooks_settings
    if is_a?(Location)
      # Merge company settings with location overrides
      company_settings = company.quickbooks_settings || {}
      location_settings = quickbooks_settings || {}
      
      company_settings.deep_merge(location_settings.deep_symbolize_keys)
    else
      # Company - just return own settings
      (quickbooks_settings || {}).deep_symbolize_keys
    end
  end
  
  # Update QuickBooks settings
  def update_quickbooks_settings!(new_settings)
    # Deep merge with existing settings
    current = quickbooks_settings || {}
    merged = current.deep_merge(new_settings.deep_symbolize_keys)
    
    update!(quickbooks_settings: merged)
  end
  
  # Disconnect from QuickBooks
  def disconnect_quickbooks!
    update_attrs = {
      quickbooks_token_expires_at: nil,
      quickbooks_realm_id: nil
    }
    
    # Use encrypted setters if they exist
    if respond_to?(:quickbooks_access_token_encrypted=)
      self.quickbooks_access_token_encrypted = nil
      self.quickbooks_refresh_token_encrypted = nil
    elsif respond_to?(:quickbooks_access_token=)
      self.quickbooks_access_token = nil
      self.quickbooks_refresh_token = nil
    end
    
    if respond_to?(:quickbooks_refresh_token_expires_at=)
      self.quickbooks_refresh_token_expires_at = nil
    end
    
    if respond_to?(:quickbooks_connection_revoked=)
      self.quickbooks_connection_revoked = true
    end
    
    save!(validate: false)
    
    Rails.logger.info "QuickBooks disconnected for #{self.class.name} ##{id}"
  end
  
  # Get QuickBooks company name from realm
  def quickbooks_company_name
    return nil unless quickbooks_connected?
    
    begin
      Rails.logger.info "[QB Company Name] Fetching for #{self.class.name}##{id}"
      
      api = QuickbooksApiService.new(self)
      Rails.logger.info "[QB Company Name] API service initialized"
      
      company_info = api.get_company_info
      Rails.logger.info "[QB Company Name] Response: #{company_info.inspect}"
      
      name = company_info.dig('CompanyInfo', 'CompanyName')
      Rails.logger.info "[QB Company Name] Extracted name: #{name.inspect}"
      
      name
    rescue => e
      Rails.logger.error "[QB Company Name] Failed: #{e.message}"
      Rails.logger.error e.backtrace.first(5).join("\n")
      nil
    end
  end
end
