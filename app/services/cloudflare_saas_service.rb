# Service for managing Cloudflare for SaaS custom hostnames
# Handles domain verification, SSL provisioning, and status monitoring
#
# Requires credentials in Rails.application.credentials:
#   cloudflare:
#     zone_id: "your-zone-id"
#     api_token: "your-api-token"
#     custom_hostname_fallback_origin: "fallback.yourdomain.com"

class CloudflareSaasService
  include HTTParty
  base_uri 'https://api.cloudflare.com/v4'
  
  class CloudflareError < StandardError; end
  
  def initialize
    @zone_id = Rails.application.credentials.dig(:cloudflare, :zone_id)
    @api_token = Rails.application.credentials.dig(:cloudflare, :api_token)
    @fallback_origin = Rails.application.credentials.dig(:cloudflare, :custom_hostname_fallback_origin)
    
    validate_credentials!
  end
  
  # Add a custom hostname to Cloudflare for SaaS
  # @param hostname [String] The domain to add (e.g., "www.sunshine-rv.com")
  # @return [Hash] Response with custom_hostname_id and verification records
  def add_custom_hostname(hostname)
    Rails.logger.info "[CloudflareSaaS] Adding custom hostname: #{hostname}"
    
    response = self.class.post(
      "/zones/#{@zone_id}/custom_hostnames",
      headers: headers,
      body: {
        hostname: hostname,
        ssl: {
          method: 'http',
          type: 'dv',
          settings: {
            http2: 'on',
            min_tls_version: '1.2',
            tls_1_3: 'on'
          }
        },
        custom_origin_server: @fallback_origin
      }.to_json
    )
    
    handle_response(response)
  end
  
  # Check the status of a custom hostname
  # @param custom_hostname_id [String] The Cloudflare custom hostname ID
  # @return [Hash] Current status including verification and SSL details
  def check_custom_hostname_status(custom_hostname_id)
    Rails.logger.info "[CloudflareSaaS] Checking status for: #{custom_hostname_id}"
    
    response = self.class.get(
      "/zones/#{@zone_id}/custom_hostnames/#{custom_hostname_id}",
      headers: headers
    )
    
    handle_response(response)
  end
  
  # Delete a custom hostname from Cloudflare
  # @param custom_hostname_id [String] The Cloudflare custom hostname ID
  # @return [Boolean] True if deleted successfully
  def delete_custom_hostname(custom_hostname_id)
    Rails.logger.info "[CloudflareSaaS] Deleting custom hostname: #{custom_hostname_id}"
    
    response = self.class.delete(
      "/zones/#{@zone_id}/custom_hostnames/#{custom_hostname_id}",
      headers: headers
    )
    
    result = handle_response(response)
    result[:success] || false
  end
  
  # Update a custom hostname's SSL settings
  # @param custom_hostname_id [String] The Cloudflare custom hostname ID
  # @param settings [Hash] SSL settings to update
  # @return [Hash] Updated custom hostname details
  def update_custom_hostname(custom_hostname_id, settings = {})
    Rails.logger.info "[CloudflareSaaS] Updating custom hostname: #{custom_hostname_id}"
    
    response = self.class.patch(
      "/zones/#{@zone_id}/custom_hostnames/#{custom_hostname_id}",
      headers: headers,
      body: settings.to_json
    )
    
    handle_response(response)
  end
  
  # Get all custom hostnames for the zone
  # @return [Array<Hash>] List of all custom hostnames
  def list_custom_hostnames
    Rails.logger.info "[CloudflareSaaS] Listing all custom hostnames"
    
    response = self.class.get(
      "/zones/#{@zone_id}/custom_hostnames",
      headers: headers
    )
    
    result = handle_response(response)
    result[:result] || []
  end
  
  # Parse Cloudflare response and extract relevant information
  # @param cf_response [Hash] Response from Cloudflare API
  # @return [Hash] Parsed domain information for database storage
  def parse_custom_hostname_response(cf_response)
    result = cf_response[:result] || {}
    ssl = result[:ssl] || {}
    ownership_verification = result[:ownership_verification] || {}
    
    {
      custom_hostname_id: result[:id],
      hostname: result[:hostname],
      verification_status: result[:status], # pending, active, moved, deleted
      verification_records: parse_verification_records(ownership_verification),
      ssl_status: ssl[:status], # pending, active, expired
      ssl_issued_at: ssl[:certificate_authority] ? Time.current : nil,
      cname_target: result[:ownership_verification]&.dig(:value),
      created_at: result[:created_at],
      updated_at: result[:updated_at]
    }
  end
  
  private
  
  def headers
    {
      'Authorization' => "Bearer #{@api_token}",
      'Content-Type' => 'application/json'
    }
  end
  
  def validate_credentials!
    if @zone_id.blank? || @api_token.blank? || @fallback_origin.blank?
      raise CloudflareError, "Cloudflare credentials not configured in credentials.yml"
    end
  end
  
  def handle_response(response)
    body = JSON.parse(response.body, symbolize_names: true) rescue {}
    
    if response.success? && body[:success]
      Rails.logger.info "[CloudflareSaaS] Request successful"
      body
    else
      errors = body[:errors] || [{ message: 'Unknown error' }]
      error_message = errors.map { |e| e[:message] }.join(', ')
      Rails.logger.error "[CloudflareSaaS] Request failed: #{error_message}"
      raise CloudflareError, error_message
    end
  end
  
  def parse_verification_records(ownership_verification)
    return [] unless ownership_verification.present?
    
    # Cloudflare typically provides HTTP or DNS verification
    type = ownership_verification[:type] || 'cname'
    name = ownership_verification[:name]
    value = ownership_verification[:value]
    
    [
      {
        type: type.upcase,
        name: name || '@',
        value: value,
        ttl: 3600,
        priority: type == 'cname' ? nil : 10
      }
    ]
  end
end
