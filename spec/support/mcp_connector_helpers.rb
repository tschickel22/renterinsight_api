# frozen_string_literal: true

# Drives the MCP connector the way Claude or ChatGPT does: register, authorize
# with PKCE, approve on the consent API as the signed-in user, exchange the
# code, then speak JSON-RPC to /mcp with the access token. Specs exercise the
# real flow end to end instead of minting tokens by hand.
module McpConnectorHelpers
  CLAUDE_REDIRECT = 'https://claude.ai/api/mcp/auth_callback'

  def connector_company(rbac: true)
    Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing', use_rbac_system: rbac).tap do |c|
      TenantModuleOverride.create!(company_id: c.id, module_key: Oauth::AccessPolicy::MODULE_KEY, is_enabled: true)
    end
  end

  def seed_rbac!
    Resource.seed_defaults
    Action.seed_defaults
    Scope.seed_defaults
  end

  # A user whose role grants exactly these permissions, e.g.
  # { 'leads' => %w[read update], 'deals' => %w[read] }. With location: the
  # role is location tier, so the user only sees that location. Any role
  # given grants also carries the ai_connector permission (read and update)
  # unless connector: says otherwise; connector: nil leaves it off.
  def connector_user(company, grants = {}, location: nil, role: 'user', connector: %w[read update])
    grants = grants.merge('ai_connector' => connector) if grants.any? && connector.present?
    user = company.users.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'Una', last_name: 'Ser',
                                 password: 'Pass1234!', role: role, status: 'active')
    if grants.any?
      tier = location ? 'location' : 'company'
      r = Role.create!(company_id: company.id, key: "r-#{SecureRandom.hex(3)}", name: 'Scoped', tier: tier, active: true)
      all_scope = Scope.find_by!(key: 'all')
      grants.each do |resource, actions|
        actions.each do |action|
          RolePermission.create!(role: r, resource: Resource.find_by!(key: resource),
                                 action: Action.find_by!(key: action), scope: all_scope, granted: true)
        end
      end
      user.user_role_assignments.create!(role: r, company_id: company.id, tier: tier, location_id: location&.id)
    end
    Rails.cache.clear
    user
  end

  def app_headers(user)
    { 'Authorization' => "Bearer #{JsonWebToken.generate_access_token(user)}" }
  end

  def register_client(redirect: CLAUDE_REDIRECT, name: 'Claude')
    post '/oauth/register', params: { client_name: name, redirect_uris: [redirect] }.to_json,
                            headers: { 'CONTENT_TYPE' => 'application/json' }
    response.parsed_body
  end

  def pkce_pair
    verifier = SecureRandom.urlsafe_base64(48)
    [verifier, Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)]
  end

  def authorize_params(client_id, challenge, scope: 'mcp:read mcp:write', redirect: CLAUDE_REDIRECT)
    { response_type: 'code', client_id: client_id, redirect_uri: redirect, code_challenge: challenge,
      code_challenge_method: 'S256', state: 'st-123', scope: scope, resource: "#{base_url}/mcp" }
  end

  # Whatever the server is configured to call itself (MCP_PUBLIC_BASE_URL or
  # RAILS_API_URL), exactly as a real client would read it from metadata.
  def base_url
    Oauth::Config.base_url
  end

  def claude_redirect
    CLAUDE_REDIRECT
  end

  # The signed request the React consent page receives in ?request=.
  def consent_request_token(client_id, challenge, **opts)
    get '/oauth/authorize', params: authorize_params(client_id, challenge, **opts)
    expect(response).to have_http_status(:found)
    Rack::Utils.parse_query(URI.parse(response.location).query)['request']
  end

  def query_of(url)
    Rack::Utils.parse_query(URI.parse(url).query)
  end

  # Full flow. Returns the token response plus the client id.
  def connect!(user, allow_write: true, scope: 'mcp:read mcp:write')
    client = register_client
    verifier, challenge = pkce_pair
    token = consent_request_token(client['client_id'], challenge, scope: scope)

    post '/api/v1/oauth/consent', params: { request: token, decision: 'approve', allow_write: allow_write },
                                  headers: app_headers(user)
    expect(response).to have_http_status(:ok), response.body
    code = query_of(response.parsed_body['redirect_url'])['code']

    post '/oauth/token', params: { grant_type: 'authorization_code', code: code, code_verifier: verifier,
                                   client_id: client['client_id'], redirect_uri: CLAUDE_REDIRECT,
                                   resource: "#{base_url}/mcp" }
    expect(response).to have_http_status(:ok), response.body
    response.parsed_body.merge('client_id' => client['client_id'])
  end

  def mcp_post(access_token, method, params = {}, id: 1)
    post '/mcp', params: { jsonrpc: '2.0', id: id, method: method, params: params }.to_json,
                 headers: { 'CONTENT_TYPE' => 'application/json', 'Accept' => 'application/json, text/event-stream',
                            'Authorization' => "Bearer #{access_token}" }
    response.parsed_body
  end

  # Returns [structured_result, is_error, text].
  def call_tool(access_token, name, arguments = {})
    body = mcp_post(access_token, 'tools/call', { name: name, arguments: arguments })
    result = body.fetch('result') { raise "JSON-RPC error: #{body['error'].inspect}" }
    [result['structuredContent'], result['isError'], result.dig('content', 0, 'text')]
  end
end

RSpec.configure do |config|
  config.include McpConnectorHelpers, :mcp
end
