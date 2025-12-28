# frozen_string_literal: true

class QuickbooksOauthService
  attr_reader :entity
  
  def initialize(entity)
    @entity = entity # Company or Location
  end
  
  def authorization_url(redirect_uri, state_token)
    params = {
      client_id: client_id,
      scope: 'com.intuit.quickbooks.accounting',
      redirect_uri: redirect_uri,
      response_type: 'code',
      state: state_token
    }
    
    base_url = 'https://appcenter.intuit.com/connect/oauth2'
    "#{base_url}?#{URI.encode_www_form(params)}"
  end
  
  def exchange_code_for_tokens!(code, redirect_uri)
    uri = URI(token_endpoint)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    
    request = Net::HTTP::Post.new(uri)
    request.basic_auth(client_id, client_secret)
    request.set_form_data({
      grant_type: 'authorization_code',
      code: code,
      redirect_uri: redirect_uri
    })
    
    response = http.request(request)
    
    if response.code == '200'
      data = JSON.parse(response.body)
      Rails.logger.info "[QuickBooks OAuth] Token response: #{data.inspect}"
      store_tokens(data)
      { success: true, data: data }
    else
      { success: false, error: parse_error_response(response) }
    end
  rescue => e
    { success: false, error: e.message }
  end
  
  def refresh_token!
    return { success: false, error: 'No refresh token' } unless entity.quickbooks_refresh_token_encrypted
    
    uri = URI(token_endpoint)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    
    request = Net::HTTP::Post.new(uri)
    request.basic_auth(client_id, client_secret)
    request.set_form_data({
      grant_type: 'refresh_token',
      refresh_token: decrypt_token(entity.quickbooks_refresh_token_encrypted)
    })
    
    response = http.request(request)
    
    if response.code == '200'
      data = JSON.parse(response.body)
      store_tokens(data)
      { success: true, data: data }
    else
      { success: false, error: parse_error_response(response) }
    end
  rescue => e
    { success: false, error: e.message }
  end
  
  def revoke_token!
    return { success: false, error: 'Not connected' } unless entity.quickbooks_connected?
    
    uri = URI(revoke_endpoint)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    
    request = Net::HTTP::Post.new(uri)
    request.basic_auth(client_id, client_secret)
    request.set_form_data({
      token: decrypt_token(entity.quickbooks_refresh_token_encrypted)
    })
    
    http.request(request)
    
    entity.disconnect_quickbooks!
    { success: true }
  rescue => e
    { success: false, error: e.message }
  end
  
  def get_company_info(realm_id, access_token)
    api = QuickbooksApiService.new(entity)
    api.get_company_info
  end
  
  private
  
  def store_tokens(data)
    expires_at = data['expires_in'].seconds.from_now
    Rails.logger.info "[QuickBooks OAuth] Storing tokens: expires_in=#{data['expires_in']}, expires_at=#{expires_at}"
    
    entity.update!(
      quickbooks_access_token_encrypted: encrypt_token(data['access_token']),
      quickbooks_refresh_token_encrypted: encrypt_token(data['refresh_token']),
      quickbooks_token_expires_at: expires_at,
      quickbooks_connected_at: Time.current
    )
    
    Rails.logger.info "[QuickBooks OAuth] Tokens stored successfully. Entity: #{entity.class.name}##{entity.id}"
  end
  
  def encrypt_token(token)
    crypt = ActiveSupport::MessageEncryptor.new(encryption_key)
    crypt.encrypt_and_sign(token)
  end
  
  def decrypt_token(encrypted_token)
    crypt = ActiveSupport::MessageEncryptor.new(encryption_key)
    crypt.decrypt_and_verify(encrypted_token)
  end
  
  def encryption_key
    Rails.application.key_generator.generate_key('quickbooks_tokens', 32)
  end
  
  def client_id
    Rails.application.credentials.dig(:quickbooks, :client_id)
  end
  
  def client_secret
    Rails.application.credentials.dig(:quickbooks, :client_secret)
  end
  
  def sandbox?
    Rails.application.credentials.dig(:quickbooks, :environment) == 'sandbox'
  end
  
  def token_endpoint
    'https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer'
  end
  
  def revoke_endpoint
    'https://developer.api.intuit.com/v2/oauth2/tokens/revoke'
  end
  
  def parse_error_response(response)
    data = JSON.parse(response.body) rescue {}
    data['error_description'] || data['error'] || 'Unknown error'
  end
end
