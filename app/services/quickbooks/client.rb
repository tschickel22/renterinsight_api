# frozen_string_literal: true

# QuickBooks Online REST API Client
# Handles OAuth token management and all QB API calls.
# Ported from RI; credential lookup adapted to DMS Setting/Rails-credentials fallback.
#
# QB API docs: https://developer.intuit.com/app/developer/qbo/docs/api/accounting/all-entities
#
# Credentials can live in either Settings (Setting w/ scope_type='Platform') or
# Rails credentials. The class checks Setting first, then falls back to credentials.
require 'net/http'
require 'json'

class Quickbooks::Client
  BASE_URL         = 'https://quickbooks.api.intuit.com'
  SANDBOX_BASE_URL = 'https://sandbox-quickbooks.api.intuit.com'

  OAUTH_TOKEN_URL  = 'https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer'
  OAUTH_REVOKE_URL = 'https://developer.api.intuit.com/v2/oauth2/tokens/revoke'

  OAUTH_AUTHORIZE_URL = 'https://appcenter.intuit.com/connect/oauth2'
  OAUTH_SCOPES = 'com.intuit.quickbooks.accounting'

  def initialize(connection)
    @connection = connection
    @realm_id   = connection.realm_id
  end

  # ── OAuth Helpers ─────────────────────────────────────────────

  def self.authorization_url(state:, redirect_uri: nil)
    params = {
      client_id:     client_id,
      redirect_uri:  redirect_uri || default_redirect_uri,
      response_type: 'code',
      scope:         OAUTH_SCOPES,
      state:         state
    }
    "#{OAUTH_AUTHORIZE_URL}?#{URI.encode_www_form(params)}"
  end

  def self.exchange_code_for_tokens(code, redirect_uri: nil)
    uri  = URI(OAUTH_TOKEN_URL)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    request = Net::HTTP::Post.new(uri)
    request['Accept'] = 'application/json'
    request['Content-Type'] = 'application/x-www-form-urlencoded'
    request.basic_auth(client_id, client_secret)
    request.set_form_data(
      grant_type:   'authorization_code',
      code:         code,
      redirect_uri: redirect_uri || default_redirect_uri
    )

    response = http.request(request)
    body     = JSON.parse(response.body)

    if response.code.to_i == 200
      body
    else
      raise QuickbooksAuthError, "Token exchange failed: #{body['error_description'] || body['error']}"
    end
  end

  def self.revoke_token(refresh_token)
    uri  = URI(OAUTH_REVOKE_URL)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    request = Net::HTTP::Post.new(uri)
    request['Accept'] = 'application/json'
    request['Content-Type'] = 'application/json'
    request.basic_auth(client_id, client_secret)
    request.body = { token: refresh_token }.to_json

    http.request(request)
  end

  # ── Token Management ──────────────────────────────────────────

  def ensure_valid_token!
    if @connection.token_expired?
      if @connection.refresh_token_expired?
        @connection.update!(status: QuickbooksConnection::STATUS_ERROR, error_message: 'Refresh token expired — please reconnect.')
        raise QuickbooksAuthError, 'Refresh token expired'
      end
      refresh_access_token!
    end
  end

  def refresh_access_token!
    uri  = URI(OAUTH_TOKEN_URL)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    request = Net::HTTP::Post.new(uri)
    request['Accept'] = 'application/json'
    request['Content-Type'] = 'application/x-www-form-urlencoded'
    request.basic_auth(self.class.client_id, self.class.client_secret)
    request.set_form_data(grant_type: 'refresh_token', refresh_token: @connection.refresh_token)

    response = http.request(request)
    body     = JSON.parse(response.body)

    if response.code.to_i == 200
      @connection.update!(
        access_token:             body['access_token'],
        refresh_token:            body['refresh_token'],
        token_expires_at:         Time.current + body['expires_in'].to_i.seconds,
        refresh_token_expires_at: Time.current + (body['x_refresh_token_expires_in'] || 8726400).to_i.seconds,
        status:                   QuickbooksConnection::STATUS_CONNECTED,
        error_message:            nil
      )
    else
      @connection.update!(status: QuickbooksConnection::STATUS_ERROR, error_message: "Token refresh failed: #{body['error']}")
      raise QuickbooksAuthError, "Token refresh failed: #{body['error']}"
    end
  end

  # ── Customer ──────────────────────────────────────────────────

  def create_customer(data)    = post("/v3/company/#{@realm_id}/customer", data)
  def update_customer(data)    = post("/v3/company/#{@realm_id}/customer", data)
  def find_customer(qb_id)     = get("/v3/company/#{@realm_id}/customer/#{qb_id}")

  # ── Invoice ───────────────────────────────────────────────────

  def create_invoice(data)     = post("/v3/company/#{@realm_id}/invoice", data)
  def update_invoice(data)     = post("/v3/company/#{@realm_id}/invoice", data)
  def find_invoice(qb_id)      = get("/v3/company/#{@realm_id}/invoice/#{qb_id}")

  # ── Payment ───────────────────────────────────────────────────

  def create_payment(data)     = post("/v3/company/#{@realm_id}/payment", data)

  # ── Credit Memo ───────────────────────────────────────────────

  def create_credit_memo(data) = post("/v3/company/#{@realm_id}/creditmemo", data)

  # ── Vendor ────────────────────────────────────────────────────

  def create_vendor(data)      = post("/v3/company/#{@realm_id}/vendor", data)
  def update_vendor(data)      = post("/v3/company/#{@realm_id}/vendor", data)

  # ── Class ─────────────────────────────────────────────────────

  def create_class(data)       = post("/v3/company/#{@realm_id}/class", data)
  def update_class(data)       = post("/v3/company/#{@realm_id}/class", data)
  def find_class(qb_id)        = get("/v3/company/#{@realm_id}/class/#{qb_id}")
  def query_classes             = query("SELECT * FROM Class WHERE Active = true MAXRESULTS 1000")

  # ── Account (Chart of Accounts) — DMS additions ───────────────

  def create_account(data)     = post("/v3/company/#{@realm_id}/account", data)
  def update_account(data)     = post("/v3/company/#{@realm_id}/account", data)
  def find_account(qb_id)      = get("/v3/company/#{@realm_id}/account/#{qb_id}")
  def query_accounts
    query("SELECT * FROM Account WHERE Active = true MAXRESULTS 1000")
  end

  # ── Journal Entry — DMS addition ──────────────────────────────

  def create_journal_entry(data) = post("/v3/company/#{@realm_id}/journalentry", data)
  def update_journal_entry(data) = post("/v3/company/#{@realm_id}/journalentry", data)
  def find_journal_entry(qb_id)  = get("/v3/company/#{@realm_id}/journalentry/#{qb_id}")

  # ── Company Info ──────────────────────────────────────────────

  def company_info
    get("/v3/company/#{@realm_id}/companyinfo/#{@realm_id}")
  end

  # ── Query ─────────────────────────────────────────────────────

  def query(sql)
    get("/v3/company/#{@realm_id}/query", query: sql)
  end

  private

  def get(path, params = {})
    api_request(:get, path, params: params)
  end

  def post(path, body = {})
    api_request(:post, path, body: body)
  end

  def api_request(method, path, params: {}, body: nil)
    ensure_valid_token!

    uri = URI("#{api_base_url}#{path}")
    uri.query = URI.encode_www_form(params) if method == :get && params.any?

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30

    request = build_request(method, uri, body)
    request['Authorization'] = "Bearer #{@connection.access_token}"
    request['Accept']        = 'application/json'
    request['Content-Type']  = 'application/json'

    response = http.request(request)
    handle_response(response, method, uri, body)
  end

  def build_request(method, uri, body)
    case method
    when :get  then Net::HTTP::Get.new(uri)
    when :post
      req = Net::HTTP::Post.new(uri)
      req.body = body.to_json if body
      req
    end
  end

  def handle_response(response, method, uri, body)
    parsed = JSON.parse(response.body) rescue {}
    code   = response.code.to_i

    return parsed if code.between?(200, 299)

    if code == 401
      refresh_access_token!
      request = build_request(method, uri, body)
      request['Authorization'] = "Bearer #{@connection.access_token}"
      request['Accept']        = 'application/json'
      request['Content-Type']  = 'application/json'

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      retry_response = http.request(request)
      retry_parsed   = JSON.parse(retry_response.body) rescue {}
      return retry_parsed if retry_response.code.to_i.between?(200, 299)
      raise QuickbooksApiError.new("QB API #{retry_response.code}: #{extract_error(retry_parsed)}", retry_response.code.to_i, retry_parsed)
    end

    raise QuickbooksApiError.new("QB API #{code}: #{extract_error(parsed)}", code, parsed)
  end

  def extract_error(parsed)
    if parsed.dig('Fault', 'Error')
      parsed['Fault']['Error'].map { |e| "#{e['Message']} — #{e['Detail']}" }.join('; ')
    elsif parsed['error']
      "#{parsed['error']}: #{parsed['error_description']}"
    else
      parsed.to_s.truncate(300)
    end
  end

  def api_base_url
    self.class.sandbox? ? SANDBOX_BASE_URL : BASE_URL
  end

  # ── Credential lookup ─────────────────────────────────────────
  # Setting (scope_type='Platform', scope_id=0) takes precedence over Rails credentials.

  def self.sandbox?
    raw = setting_value('quickbooks_sandbox')
    return raw.to_s == 'true' if raw
    Rails.application.credentials.dig(:quickbooks, :sandbox) == true
  end

  def self.client_id
    setting_value('quickbooks_client_id') ||
      Rails.application.credentials.dig(:quickbooks, :client_id)
  end

  def self.client_secret
    setting_value('quickbooks_client_secret') ||
      Rails.application.credentials.dig(:quickbooks, :client_secret)
  end

  def self.default_redirect_uri
    setting_value('quickbooks_redirect_uri') ||
      Rails.application.credentials.dig(:quickbooks, :redirect_uri) ||
      'http://localhost:3002/api/v1/quickbooks/callback'
  end

  def self.setting_value(key)
    Setting.find_by(scope_type: 'Platform', scope_id: PlatformSetting::PLATFORM_SCOPE_ID, key: key)&.value
  rescue StandardError
    nil
  end
end

# QuickbooksApiError, QuickbooksAuthError, QuickbooksValidationError,
# QuickbooksRateLimitError, QuickbooksServerError moved to individual files
# under app/services/ so Zeitwerk can auto-load them. This file used to
# define them inline; that made them invisible to the autoloader and every
# `rescue QuickbooksValidationError` blew up with an uninitialized-constant
# NameError as soon as an actual QB error hit the rescue evaluation.
