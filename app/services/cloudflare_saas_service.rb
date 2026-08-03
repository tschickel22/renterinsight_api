# Service for managing Cloudflare for SaaS custom hostnames
# Handles domain verification, SSL provisioning, and status monitoring
#
# Configuration comes from environment variables, falling back to Rails encrypted
# credentials for anyone already using them:
#
#   CLOUDFLARE_ZONE_ID
#   CLOUDFLARE_API_TOKEN                       (needs SSL and Certificates: Edit)
#   CLOUDFLARE_CUSTOM_HOSTNAME_FALLBACK_ORIGIN
#
# ENV wins because that is what our host actually offers. Encrypted credentials require
# RAILS_MASTER_KEY and a redeploy to change, which makes rotating an API token a code
# change rather than a settings change.

class CloudflareSaasService
  include HTTParty
  # Cloudflare's REST base is /client/v4, not /v4. Getting this wrong returns
  # {"code":10404,"message":"No route for that URI"} on every call, which reads like a bad
  # endpoint or a permissions problem rather than a wrong base path.
  base_uri 'https://api.cloudflare.com/client/v4'

  class CloudflareError < StandardError; end

  def initialize
    @zone_id = setting(:zone_id, 'CLOUDFLARE_ZONE_ID')
    @api_token = setting(:api_token, 'CLOUDFLARE_API_TOKEN')
    @fallback_origin = setting(:custom_hostname_fallback_origin, 'CLOUDFLARE_CUSTOM_HOSTNAME_FALLBACK_ORIGIN')

    validate_credentials!
  end

  # The hostname a tenant points their domain at. Cloudflare never returns this — it is our
  # configuration, and it is the single record without which nothing works: ownership can
  # verify from a TXT record while traffic still has nowhere to go and the certificate
  # never issues.
  #
  # Falls back to the fallback origin, which is also proxied and therefore also routes,
  # so a missing CLOUDFLARE_CNAME_TARGET degrades rather than leaving tenants with no
  # target at all.
  def cname_target
    ENV['CLOUDFLARE_CNAME_TARGET'].presence ||
      Rails.application.credentials.dig(:cloudflare, :cname_target).presence ||
      @fallback_origin
  end

  # True when Cloudflare for SaaS is configured, without raising. Lets callers offer or
  # hide custom-domain features rather than discovering the gap through an exception.
  def self.configured?
    new
    true
  rescue CloudflareError
    false
  end
  
  # Add a custom hostname to Cloudflare for SaaS
  # @param hostname [String] The domain to add (e.g., "www.sunshine-rv.com")
  # @return [Hash] Response with custom_hostname_id and verification records
  def add_custom_hostname(hostname)
    Rails.logger.info "[CloudflareSaaS] Adding custom hostname: #{hostname}"

    response = post_custom_hostname(hostname, custom_origin: true)

    # custom_origin_server has restricted availability on some Cloudflare plans. Without
    # this, a plan that rejects it would fail every dealer domain outright, when the
    # zone-level fallback origin does the same job for our purposes: we point every custom
    # hostname at the one origin anyway.
    if rejected_custom_origin?(response)
      Rails.logger.warn(
        "[CloudflareSaaS] custom_origin_server rejected for #{hostname}; retrying with the " \
        'zone fallback origin. Confirm the fallback origin is set under SSL/TLS > Custom Hostnames.'
      )
      response = post_custom_hostname(hostname, custom_origin: false)
    end

    # Cloudflare refuses a hostname it already holds. That happens whenever a previous
    # attempt provisioned successfully and then failed on our side, which strands the
    # tenant: the hostname is unusable here and invisible to them, and no amount of
    # retrying clears it. Adopt the existing one instead of reporting a duplicate.
    return adopt_existing_hostname(hostname) if duplicate_hostname?(response)

    handle_response(response)
  end

  # Finds a hostname Cloudflare already holds and returns it in the same shape as a fresh
  # create, so callers cannot tell the difference.
  def adopt_existing_hostname(hostname)
    Rails.logger.info "[CloudflareSaaS] Adopting existing custom hostname: #{hostname}"

    existing = list_custom_hostnames.find { |h| h[:hostname].to_s.casecmp?(hostname.to_s) }
    raise CloudflareError, "Duplicate hostname reported but #{hostname} was not found" if existing.nil?

    { success: true, result: existing }
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
  
  def post_custom_hostname(hostname, custom_origin:)
    body = {
      hostname: hostname,
      ssl: {
        method: 'http',
        type: 'dv',
        settings: { http2: 'on', min_tls_version: '1.2', tls_1_3: 'on' }
      }
    }
    body[:custom_origin_server] = @fallback_origin if custom_origin

    self.class.post("/zones/#{@zone_id}/custom_hostnames", headers: headers, body: body.to_json)
  end

  def duplicate_hostname?(response)
    return false if response.success?

    response.body.to_s.match?(/duplicate custom hostname/i)
  rescue StandardError
    false
  end

  # Cloudflare reports an unavailable field as a 4xx with an error mentioning it, rather
  # than a distinct status, so the message is what we have to key on.
  def rejected_custom_origin?(response)
    return false if response.success?

    body = response.body.to_s
    body.match?(/custom_origin_server/i) ||
      body.match?(/not (available|entitled|authorized)/i)
  rescue StandardError
    false
  end

  def setting(credential_key, env_key)
    ENV[env_key].presence || Rails.application.credentials.dig(:cloudflare, credential_key)
  end

  def validate_credentials!
    missing = {
      'CLOUDFLARE_ZONE_ID' => @zone_id,
      'CLOUDFLARE_API_TOKEN' => @api_token,
      'CLOUDFLARE_CUSTOM_HOSTNAME_FALLBACK_ORIGIN' => @fallback_origin
    }.select { |_k, v| v.blank? }.keys

    return if missing.empty?

    raise CloudflareError, "Cloudflare for SaaS not configured. Missing: #{missing.join(', ')}"
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
