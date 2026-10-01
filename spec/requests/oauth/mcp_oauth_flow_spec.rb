# frozen_string_literal: true

require 'rails_helper'
require_relative '../../support/mcp_connector_helpers'

# The OAuth authorization server Claude and ChatGPT sign in through. Each
# example follows what one of those apps actually sends.
RSpec.describe 'MCP connector OAuth', :mcp, type: :request do
  before { seed_rbac! }

  let(:company) { connector_company }
  let(:user) { connector_user(company, { 'leads' => %w[read] }) }

  describe 'discovery' do
    it 'publishes protected resource metadata at the root and the /mcp suffix' do
      %w[/.well-known/oauth-protected-resource /.well-known/oauth-protected-resource/mcp].each do |path|
        get path
        expect(response.parsed_body).to include(
          'resource' => "#{base_url}/mcp", 'authorization_servers' => [base_url]
        )
      end
    end

    it 'publishes authorization server metadata with what ChatGPT requires' do
      get '/.well-known/oauth-authorization-server'

      expect(response.parsed_body).to include(
        'issuer' => base_url,
        'code_challenge_methods_supported' => ['S256'],
        'token_endpoint_auth_methods_supported' => ['none'],
        'client_id_metadata_document_supported' => true,
        'authorization_response_iss_parameter_supported' => true,
        'registration_endpoint' => "#{base_url}/oauth/register"
      )
    end

    it 'challenges an unauthenticated MCP call so the client can find all of the above' do
      post '/mcp', params: { jsonrpc: '2.0', id: 1, method: 'initialize' }.to_json,
                   headers: { 'CONTENT_TYPE' => 'application/json' }

      expect(response).to have_http_status(:unauthorized)
      expect(response.headers['WWW-Authenticate'])
        .to include(%(resource_metadata="#{base_url}/.well-known/oauth-protected-resource"))
      # Both scopes, or Claude only ever asks for read and changes can never be allowed.
      expect(response.headers['WWW-Authenticate']).to include('scope="mcp:read mcp:write"')
    end
  end

  describe 'registration' do
    it 'registers a public client for an allowed redirect' do
      body = register_client

      expect(response).to have_http_status(:created)
      expect(body).to include('token_endpoint_auth_method' => 'none', 'redirect_uris' => [claude_redirect])
      expect(body['client_id']).to start_with('dtc_')
    end

    it 'refuses a redirect to anywhere but the AI apps and loopback' do
      register_client(redirect: 'https://dealertide-assistant.example.com/callback')

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['error']).to eq('invalid_redirect_uri')
    end

    it "refuses other paths on the AI apps' own hosts, such as a stranger's Custom GPT callback" do
      register_client(redirect: 'https://chatgpt.com/aip/g-attacker/oauth/callback')
      expect(response).to have_http_status(:bad_request)

      register_client(redirect: 'https://chatgpt.com/connector/oauth/abc123')
      expect(response).to have_http_status(:created)
    end

    it 'accepts a loopback redirect on any port, as desktop and CLI clients use' do
      client = register_client(redirect: 'http://127.0.0.1/callback')
      _verifier, challenge = pkce_pair

      get '/oauth/authorize', params: authorize_params(client['client_id'], challenge,
                                                       redirect: 'http://127.0.0.1:53682/callback')

      expect(response).to have_http_status(:found)
      expect(response.location).to include('/oauth/consent?request=')
    end
  end

  describe 'authorize' do
    let(:client) { register_client }

    it 'sends the browser to the consent page with a signed request' do
      _verifier, challenge = pkce_pair
      get '/oauth/authorize', params: authorize_params(client['client_id'], challenge)

      expect(response.location).to start_with("#{Brand.app_url}/oauth/consent?request=")
    end

    it 'shows an error and does not redirect when the redirect URI is not registered' do
      _verifier, challenge = pkce_pair
      get '/oauth/authorize', params: authorize_params(client['client_id'], challenge)
        .merge(redirect_uri: 'https://claude.ai/somewhere-else')

      expect(response).to have_http_status(:bad_request)
      expect(response.location).to be_nil
    end

    it 'sends a missing PKCE back to the app as an error, with iss' do
      get '/oauth/authorize', params: authorize_params(client['client_id'], 'x').except(:code_challenge)

      params = query_of(response.location)
      expect(response.location).to start_with(claude_redirect)
      expect(params).to include('error' => 'invalid_request', 'state' => 'st-123', 'iss' => base_url)
    end

    it 'refuses a token for another resource' do
      _verifier, challenge = pkce_pair
      get '/oauth/authorize', params: authorize_params(client['client_id'], challenge)
        .merge(resource: 'https://other.example.com/mcp')

      expect(query_of(response.location)['error']).to eq('invalid_target')
    end
  end

  describe 'consent' do
    let(:client) { register_client }
    let(:challenge) { pkce_pair.last }

    it 'describes the request to the signed-in user' do
      token = consent_request_token(client['client_id'], challenge)
      get '/api/v1/oauth/consent', params: { request: token }, headers: app_headers(user)

      expect(response.parsed_body).to include(
        'can_connect' => true, 'scopes' => %w[mcp:read mcp:write], 'redirect_host' => 'claude.ai'
      )
      expect(response.parsed_body.dig('client', 'name')).to eq('Claude')
    end

    it 'returns access_denied to the app when the user declines' do
      token = consent_request_token(client['client_id'], challenge)
      post '/api/v1/oauth/consent', params: { request: token, decision: 'deny' }, headers: app_headers(user)

      expect(query_of(response.parsed_body['redirect_url'])).to include('error' => 'access_denied', 'iss' => base_url)
      expect(OauthGrant.count).to eq(0)
    end

    it 'grants read only unless the user ticks allow changes' do
      token = consent_request_token(client['client_id'], challenge)
      post '/api/v1/oauth/consent', params: { request: token, decision: 'approve', allow_write: false },
                                    headers: app_headers(user)

      expect(OauthGrant.last.scope_list).to eq(['mcp:read'])
    end

    it 'refuses when the company does not have the add-on' do
      TenantModuleOverride.where(company_id: company.id).delete_all
      token = consent_request_token(client['client_id'], challenge)
      post '/api/v1/oauth/consent', params: { request: token, decision: 'approve' }, headers: app_headers(user)

      expect(response).to have_http_status(:forbidden)
      expect(OauthGrant.count).to eq(0)
    end

    it 'refuses platform admins, whose access is not tied to one company' do
      admin = company.users.create!(email: "p-#{SecureRandom.hex(3)}@example.com", first_name: 'P', last_name: 'A',
                                    password: 'Pass1234!', role: 'platform_admin', status: 'active')
      token = consent_request_token(client['client_id'], challenge)
      post '/api/v1/oauth/consent', params: { request: token, decision: 'approve' },
                                    headers: { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: admin.id, company_id: company.id)}" }

      expect(response).to have_http_status(:forbidden)
    end

    it 'rejects a tampered request token' do
      post '/api/v1/oauth/consent', params: { request: 'forged--token', decision: 'approve' }, headers: app_headers(user)

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe 'tokens' do
    it 'exchanges a code for tokens that open /mcp' do
      tokens = connect!(user)

      expect(tokens).to include('token_type' => 'Bearer', 'expires_in' => 3600, 'scope' => 'mcp:read mcp:write')
      body = mcp_post(tokens['access_token'], 'ping')
      expect(body).to include('result' => {})
    end

    it 'refuses a wrong PKCE verifier' do
      client = register_client
      _verifier, challenge = pkce_pair
      token = consent_request_token(client['client_id'], challenge)
      post '/api/v1/oauth/consent', params: { request: token, decision: 'approve' }, headers: app_headers(user)
      code = query_of(response.parsed_body['redirect_url'])['code']

      post '/oauth/token', params: { grant_type: 'authorization_code', code: code, client_id: client['client_id'],
                                     code_verifier: pkce_pair.first, redirect_uri: claude_redirect }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['error']).to eq('invalid_grant')
    end

    it 'treats a reused code as stolen and revokes what it issued' do
      client = register_client
      verifier, challenge = pkce_pair
      token = consent_request_token(client['client_id'], challenge)
      post '/api/v1/oauth/consent', params: { request: token, decision: 'approve' }, headers: app_headers(user)
      code = query_of(response.parsed_body['redirect_url'])['code']
      exchange = { grant_type: 'authorization_code', code: code, client_id: client['client_id'],
                   code_verifier: verifier, redirect_uri: claude_redirect }

      post '/oauth/token', params: exchange
      first = response.parsed_body
      post '/oauth/token', params: exchange

      expect(response.parsed_body['error']).to eq('invalid_grant')
      expect(mcp_post(first['access_token'], 'ping')).not_to have_key('result')
      expect(response).to have_http_status(:unauthorized)
    end

    it 'rotates refresh tokens and revokes the grant when an old one is replayed' do
      tokens = connect!(user)
      refresh = { grant_type: 'refresh_token', refresh_token: tokens['refresh_token'], client_id: tokens['client_id'] }

      post '/oauth/token', params: refresh
      rotated = response.parsed_body
      expect(rotated['refresh_token']).not_to eq(tokens['refresh_token'])

      post '/oauth/token', params: refresh
      expect(response.parsed_body['error']).to eq('invalid_grant')
      expect(OauthGrant.last.revoked_at).to be_present
    end

    it 'keeps a refresh narrowed to read only from writing, even though the grant allows it' do
      tokens = connect!(user)
      post '/oauth/token', params: { grant_type: 'refresh_token', refresh_token: tokens['refresh_token'],
                                     client_id: tokens['client_id'], scope: 'mcp:read' }
      narrowed = response.parsed_body['access_token']

      names = mcp_post(narrowed, 'tools/list').dig('result', 'tools').map { |t| t['name'] }
      expect(names).not_to include('create_lead')
    end

    it 'stores no plaintext token' do
      tokens = connect!(user)

      expect(OauthToken.where(token_digest: tokens['access_token'])).to be_empty
      expect(OauthToken.where(token_digest: OauthToken.digest(tokens['access_token']))).to exist
    end
  end

  describe 'cutting a connection off' do
    let!(:tokens) { connect!(user) }

    # A permission the person lacks right now is 403 with the reason, not 401:
    # signing in again cannot fix it, and 401 made Claude say "Authentication
    # failed" and loop through sign-in.
    it 'stops working as soon as the add-on is removed, and says why' do
      TenantModuleOverride.where(company_id: company.id).delete_all
      body = mcp_post(tokens['access_token'], 'ping')
      expect(response).to have_http_status(:forbidden)
      expect(body.dig('error', 'message')).to include('not enabled for this company')
    end

    it 'stops working when the company is suspended' do
      company.update_columns(status: 'suspended')
      mcp_post(tokens['access_token'], 'ping')
      expect(response).to have_http_status(:forbidden)
    end

    it 'keeps the refresh token through a refusal, so it works again once access is back' do
      TenantModuleOverride.where(company_id: company.id).delete_all
      refresh = { grant_type: 'refresh_token', refresh_token: tokens['refresh_token'], client_id: tokens['client_id'] }
      post '/oauth/token', params: refresh
      expect(response.parsed_body['error']).to eq('invalid_grant')

      TenantModuleOverride.create!(company_id: company.id, module_key: Oauth::AccessPolicy::MODULE_KEY, is_enabled: true)
      post '/oauth/token', params: refresh
      expect(response).to have_http_status(:ok)
      expect(mcp_post(response.parsed_body['access_token'], 'ping')).to include('result' => {})
    end

    it 'stops working when the app revokes its refresh token' do
      post '/oauth/revoke', params: { token: tokens['refresh_token'] }
      expect(response).to have_http_status(:ok)

      mcp_post(tokens['access_token'], 'ping')
      expect(response).to have_http_status(:unauthorized)
    end

    it 'stops working when the user disconnects it in Settings' do
      get '/api/v1/connected-apps', headers: app_headers(user)
      connection = response.parsed_body['connections'].first
      expect(connection).to include('app_name' => 'Claude', 'is_mine' => true)

      delete "/api/v1/connected-apps/#{connection['id']}", headers: app_headers(user)
      mcp_post(tokens['access_token'], 'ping')
      expect(response).to have_http_status(:unauthorized)
    end

    it "does not show one user's connection to another non-admin" do
      other = connector_user(company, { 'leads' => %w[read] })
      get '/api/v1/connected-apps', headers: app_headers(other)

      expect(response.parsed_body['connections']).to be_empty
      delete "/api/v1/connected-apps/#{OauthGrant.last.id}", headers: app_headers(other)
      expect(response).to have_http_status(:not_found)
    end
  end
end
