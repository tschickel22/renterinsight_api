# frozen_string_literal: true

# HTTP client for the Champion Retailer Leads API.
#
# Swagger:    https://digs-api-prod.championhomes.com/swagger/index.html
# Stage URL:  https://digs-api-stage.championhomes.com
# Prod URL:   https://digs-api-prod.championhomes.com
#
# Auth: X-API-Key header with the token generated from DIGS portal.
#
# Endpoints:
#   GET  /api/external/leads/AuthTest          — connection test
#   GET  /api/external/leads/download          — bulk download all leads
#   GET  /api/external/leads                   — paginated list
#   GET  /api/external/leads/{id}              — single lead detail
#   PUT  /api/external/leads/{id}/accept       — accept (unlocks contact info)
#   PUT  /api/external/leads/{id}/decline      — decline with reason
#   PUT  /api/external/leads/{id}/status       — update lead status
#   GET  /api/health                           — health check
#
# Usage:
#   config = ChampionLeadFeedConfig.find(1)
#   client = ChampionLeadsApiClient.new(config)
#   result = client.auth_test
#   #=> { success: true, data: ..., status: 200 }
class ChampionLeadsApiClient
  include HTTParty

  # Path templates — %{id} is interpolated with the Salesforce ID
  PATHS = {
    auth_test: '/api/external/leads/AuthTest',
    download:  '/api/external/leads/download',
    leads:     '/api/external/leads',
    lead:      '/api/external/leads/%{id}',
    accept:    '/api/external/leads/%{id}/accept',
    decline:   '/api/external/leads/%{id}/decline',
    status:    '/api/external/leads/%{id}/status',
    health:    '/api/health'
  }.freeze

  attr_reader :config

  def initialize(config)
    @config   = config
    @base_url = config.api_base_url
    @api_key  = config.api_token
  end

  # ----------------------------------------------------------------
  # Read endpoints
  # ----------------------------------------------------------------

  # Test connectivity and API key validity
  def auth_test
    api_get(:auth_test)
  end

  # Health check (no auth required)
  def health
    api_get(:health)
  end

  # Bulk download ALL leads (use for initial sync or full reconciliation)
  def download_all
    api_get(:download)
  end

  # Paginated lead list with optional filters
  def list_leads(page: 1, page_size: 50, status: nil, search: nil)
    params = { page: page, pageSize: page_size }
    params[:status] = status if status.present?
    params[:search] = search if search.present?
    api_get(:leads, params: params)
  end

  # Fetch a single lead by Salesforce ID
  def get_lead(salesforce_id)
    api_get(:lead, id: salesforce_id)
  end

  # ----------------------------------------------------------------
  # Write endpoints
  # ----------------------------------------------------------------

  # Accept a lead — reveals the prospect's contact info (email/phone).
  # Idempotent: re-accepting an already-accepted lead returns 200.
  def accept_lead(salesforce_id)
    api_put(:accept, id: salesforce_id)
  end

  # Decline a lead with an optional reason string.
  # Idempotent: re-declining returns 200.
  def decline_lead(salesforce_id, reason: nil)
    body = {}
    body[:declineReason] = reason if reason.present?
    api_put(:decline, id: salesforce_id, body: body)
  end

  # Update the status of an accepted lead.
  def update_status(salesforce_id, status:, sub_status: nil, final_disposition: nil)
    body = { status: status }
    body[:subStatus]        = sub_status if sub_status.present?
    body[:finalDisposition] = final_disposition if final_disposition.present?
    api_put(:status, id: salesforce_id, body: body)
  end

  private

  # ----------------------------------------------------------------
  # HTTP plumbing (HTTParty)
  # ----------------------------------------------------------------

  def api_get(path_key, id: nil, params: {})
    url = build_url(path_key, id)
    response = self.class.get(url, headers: headers, query: params, timeout: 30)
    handle_response(response)
  rescue StandardError => e
    { success: false, error: "Connection error: #{e.message}", status: nil }
  end

  def api_put(path_key, id: nil, body: {})
    url = build_url(path_key, id)
    options = { headers: headers, timeout: 30 }
    options[:body] = body.to_json if body.present?
    response = self.class.put(url, options)
    handle_response(response)
  rescue StandardError => e
    { success: false, error: "Connection error: #{e.message}", status: nil }
  end

  def build_url(path_key, id)
    path = PATHS.fetch(path_key)
    path = format(path, id: id) if id
    "#{@base_url}#{path}"
  end

  def headers
    {
      'X-API-Key'    => @api_key,
      'Content-Type' => 'application/json',
      'Accept'       => 'application/json'
    }
  end

  def handle_response(response)
    case response.code
    when 200..299
      data = response.parsed_response
      { success: true, data: data, status: response.code }
    when 401
      { success: false, error: 'Invalid or expired API key', status: 401 }
    when 403
      { success: false, error: 'API access disabled for this retailer', status: 403 }
    when 404
      { success: false, error: 'Lead not found', status: 404 }
    when 429
      { success: false, error: 'Rate limited — try again later', status: 429 }
    else
      { success: false, error: "Champion API error (HTTP #{response.code})",
        status: response.code, body: response.parsed_response }
    end
  end
end
