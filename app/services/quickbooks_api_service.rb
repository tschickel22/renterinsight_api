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
  
  # GET request to QuickBooks API
  def get(endpoint, params = {})
    url = build_url(endpoint)
    
    response = HTTParty.get(url, {
      headers: auth_headers,
      query: params,
      timeout: 30
    })
    
    handle_response(response)
  end
  
  # POST request to QuickBooks API
  def post(endpoint, data)
    url = build_url(endpoint)
    
    response = HTTParty.post(url, {
      headers: auth_headers.merge('Content-Type' => 'application/json'),
      body: data.to_json,
      timeout: 30
    })
    
    handle_response(response)
  end
  
  # POST with sparse update (PATCH equivalent)
  def update(endpoint, id, data)
    url = build_url(endpoint)
    
    # QuickBooks updates use POST with Id and SyncToken in body
    # NO query parameters - that causes "Unsupported Operation"
    response = HTTParty.post(url, {
      headers: auth_headers.merge('Content-Type' => 'application/json'),
      body: data.to_json,
      timeout: 30
    })
    
    handle_response(response)
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
  
  # Search for entities
  def search_entities(entity_type, conditions = {})
    # Build SQL query
    sql = "SELECT * FROM #{entity_type}"
    
    if conditions.any?
      where_clauses = conditions.map { |field, value| "#{field} = '#{value}'" }
      sql += " WHERE #{where_clauses.join(' AND ')}"
    end
    
    query(sql)
  end
  
  # Get all entities of a type
  def get_all_entities(entity_type, max_results: 1000)
    results = []
    start_position = 1
    
    loop do
      sql = "SELECT * FROM #{entity_type} STARTPOSITION #{start_position} MAXRESULTS 1000"
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
    case response.code
    when 200, 201
      response.parsed_response
    when 401
      # Token expired or invalid
      raise QuickbooksAuthError, "Authentication failed: #{response.body}"
    when 400
      # Bad request
      error_msg = extract_error_message(response)
      raise QuickbooksValidationError, "Validation error: #{error_msg}"
    when 429
      # Rate limit
      raise QuickbooksRateLimitError, "Rate limit exceeded"
    when 500, 502, 503
      # Server error
      raise QuickbooksServerError, "QuickBooks server error: #{response.code}"
    else
      raise QuickbooksApiError, "API request failed: #{response.code} - #{response.body}"
    end
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

# Custom exception classes
class QuickbooksApiError < StandardError; end
class QuickbooksAuthError < QuickbooksApiError; end
class QuickbooksValidationError < QuickbooksApiError; end
class QuickbooksRateLimitError < QuickbooksApiError; end
class QuickbooksServerError < QuickbooksApiError; end
