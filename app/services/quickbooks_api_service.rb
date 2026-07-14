# frozen_string_literal: true

# QuickBooks API Service
# Handles all API calls to QuickBooks Online API
# Manages OAuth token refresh and error handling

class QuickbooksApiService
  attr_reader :entity, :access_token, :realm_id
  
  BASE_URL = 'https://quickbooks.api.intuit.com/v3/company'
  SANDBOX_URL = 'https://sandbox-quickbooks.api.intuit.com/v3/company'
  
  def initialize(entity)
    @entity = entity # Can be Company or Location
    
    # Refresh token if expired
    if entity.quickbooks_token_expired?
      result = entity.refresh_quickbooks_token!
      raise "Failed to refresh token: #{result[:error]}" unless result[:success]
    end
    
    @access_token = entity.quickbooks_access_token
    @realm_id = entity.quickbooks_realm_id
    
    raise "QuickBooks not connected" unless @access_token.present? && @realm_id.present?
  end
  
  # Every request should send minorversion so QB doesn't silently drift to an
  # older schema — some fields (custom fields, tax detail) only exist above
  # certain minorversions.
  MINOR_VERSION = 65

  # 429 backoff — retry up to 3 times with exponential delay before giving
  # up. QB rate limits are per-app-per-realm; a caller should see a real
  # rate-limit error only after all retries fail.
  RATE_LIMIT_RETRY_LIMIT = 3
  RATE_LIMIT_BACKOFF_BASE_SECONDS = 2

  # GET request to QuickBooks API
  def get(endpoint, params = {})
    url = build_url(endpoint)

    with_rate_limit_retry do
      response = HTTParty.get(url, {
        headers: auth_headers,
        query: params.reverse_merge(minorversion: MINOR_VERSION),
        timeout: 30
      })
      handle_response(response)
    end
  end

  # POST request to QuickBooks API
  def post(endpoint, data)
    url = build_url(endpoint)

    with_rate_limit_retry do
      response = HTTParty.post(url, {
        headers: auth_headers.merge('Content-Type' => 'application/json'),
        query: { minorversion: MINOR_VERSION },
        body: data.to_json,
        timeout: 30
      })
      handle_response(response)
    end
  end

  # POST with sparse update (PATCH equivalent)
  def update(endpoint, id, data)
    url = build_url(endpoint)

    with_rate_limit_retry do
      # QuickBooks updates use POST with Id and SyncToken in body.
      # minorversion goes in the query string (not the body) so we still
      # get the newer schema without confusing QB about the operation.
      response = HTTParty.post(url, {
        headers: auth_headers.merge('Content-Type' => 'application/json'),
        query: { minorversion: MINOR_VERSION },
        body: data.to_json,
        timeout: 30
      })
      handle_response(response)
    end
  end

  # Query QuickBooks data with SQL-like syntax
  def query(sql_query)
    get('query', { query: sql_query })
  end
  
  # Get company info (useful for testing connection)
  def get_company_info
    # CompanyInfo endpoint requires the realm ID as the resource ID
    get("companyinfo/#{@realm_id}", { minorversion: 65 })
  end
  
  # Get specific entity by ID
  def get_entity(entity_type, id)
    # QuickBooks API endpoints are lowercase
    get("#{entity_type.downcase}/#{id}", { minorversion: 65 })
  end
  
  # Create entity
  def create_entity(entity_type, data)
    # QuickBooks API endpoints are lowercase
    post(entity_type.downcase, data)
  end
  
  # Update entity
  def update_entity(entity_type, id, data)
    # QuickBooks API endpoints are lowercase
    update(entity_type.downcase, id, data)
  end
  
  # Search for entities. QB's query language uses SQL-ish syntax with single
  # quotes; values are escaped by doubling embedded single quotes. Field
  # names are only allowed if they match a plain [A-Za-z0-9_.] pattern so a
  # caller can't inject SQL through the field name either.
  def search_entities(entity_type, conditions = {})
    sql = "SELECT * FROM #{sanitize_qb_identifier(entity_type)}"

    if conditions.any?
      where_clauses = conditions.map do |field, value|
        "#{sanitize_qb_identifier(field)} = '#{escape_qb_value(value)}'"
      end
      sql += " WHERE #{where_clauses.join(' AND ')}"
    end

    query(sql)
  end
  
  # Get all entities of a type, optionally filtered to those changed after
  # a given time (real from-QB incremental). QB supports the standard SQL
  # WHERE clause on MetaData.LastUpdatedTime with an ISO 8601 timestamp.
  # `entity_type` is validated at the boundary so it can't be a SQL vector.
  def get_all_entities(entity_type, max_results: 1000, since: nil)
    safe_type = sanitize_qb_identifier(entity_type)
    results = []
    start_position = 1

    where_clause =
      if since
        ts = since.respond_to?(:utc) ? since.utc.iso8601 : since.to_s
        " WHERE MetaData.LastUpdatedTime > '#{escape_qb_value(ts)}'"
      else
        ''
      end

    loop do
      sql = "SELECT * FROM #{safe_type}#{where_clause} STARTPOSITION #{start_position} MAXRESULTS 1000"
      response = query(sql)

      entities = response.dig('QueryResponse', entity_type) || []
      results.concat(entities)

      break if entities.length < 1000 || results.length >= max_results
      start_position += 1000
    end

    results
  end
  
  private
  
  def build_url(endpoint)
    # Use ENV var for environment (Render/Production) or Rails.env for local dev
    is_sandbox = (ENV['QUICKBOOKS_ENVIRONMENT'] || Rails.application.credentials.dig(:quickbooks, :environment)) == 'sandbox'
    base = is_sandbox ? SANDBOX_URL : BASE_URL
    "#{base}/#{@realm_id}/#{endpoint}"
  end
  
  def auth_headers
    {
      'Authorization' => "Bearer #{@access_token}",
      'Accept' => 'application/json'
    }
  end
  
  def handle_response(response)
    # CRITICAL: Capture intuit_tid for debugging (required by QuickBooks)
    intuit_tid = response.headers['intuit_tid']
    
    case response.code
    when 200, 201
      # Log successful request with intuit_tid
      Rails.logger.info "[QB API Success] intuit_tid: #{intuit_tid}" if intuit_tid.present?
      response.parsed_response
    when 401
      # Token expired or invalid
      Rails.logger.error "[QB API Error 401] intuit_tid: #{intuit_tid}" if intuit_tid.present?
      raise QuickbooksAuthError, "Authentication failed: #{response.body}"
    when 400
      # Bad request
      Rails.logger.error "[QB API Error 400] intuit_tid: #{intuit_tid}" if intuit_tid.present?
      error_msg = extract_error_message(response)
      raise QuickbooksValidationError, "Validation error: #{error_msg}"
    when 429
      # Rate limit
      Rails.logger.error "[QB API Error 429] intuit_tid: #{intuit_tid}" if intuit_tid.present?
      raise QuickbooksRateLimitError, "Rate limit exceeded"
    when 500, 502, 503
      # Server error
      Rails.logger.error "[QB API Error #{response.code}] intuit_tid: #{intuit_tid}" if intuit_tid.present?
      raise QuickbooksServerError, "QuickBooks server error: #{response.code}"
    else
      Rails.logger.error "[QB API Error #{response.code}] intuit_tid: #{intuit_tid}" if intuit_tid.present?
      raise QuickbooksApiError, "API request failed: #{response.code} - #{response.body}"
    end
  end
  
  # Wrap a QB request in bounded exponential retries when QB replies with
  # 429 (rate limit). Anything else propagates immediately.
  def with_rate_limit_retry
    attempts = 0
    begin
      yield
    rescue QuickbooksRateLimitError => e
      attempts += 1
      raise if attempts > RATE_LIMIT_RETRY_LIMIT

      sleep_for = RATE_LIMIT_BACKOFF_BASE_SECONDS**attempts
      Rails.logger.warn "[QB API] 429 rate-limited, retrying in #{sleep_for}s (attempt #{attempts}/#{RATE_LIMIT_RETRY_LIMIT})"
      sleep(sleep_for)
      retry
    end
  end

  # QB identifiers (entity + field names) come from code in practice, but
  # search_entities has been called with dynamic values in the past, so
  # enforce the shape at the boundary.
  def sanitize_qb_identifier(identifier)
    str = identifier.to_s
    raise ArgumentError, "Unsafe QB identifier: #{str.inspect}" unless str.match?(/\A[A-Za-z_][A-Za-z0-9_.]*\z/)
    str
  end

  # QB SQL uses single-quoted string literals; embedded ' is escaped by
  # doubling.
  def escape_qb_value(value)
    value.to_s.gsub("'", "''")
  end

  def extract_error_message(response)
    parsed = response.parsed_response
    
    if parsed.is_a?(Hash)
      fault = parsed.dig('Fault', 'Error', 0)
      return fault['Message'] if fault
      
      return parsed['message'] if parsed['message']
    end
    
    response.body
  end
end

# Custom exception classes defined in app/services/quickbooks/client.rb
# QuickbooksApiError, QuickbooksAuthError, QuickbooksValidationError,
# QuickbooksRateLimitError, QuickbooksServerError
