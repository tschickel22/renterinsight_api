# frozen_string_literal: true

require 'rails_helper'
require_relative '../../support/mcp_connector_helpers'

# Who may connect Claude or ChatGPT is a role permission, ai_connector, not
# just the company's add-on: Read to connect, Update to let the AI make
# changes. Admins have it; every other role starts without it.
RSpec.describe 'AI connector permission', :mcp, type: :request do
  before { seed_rbac! }

  let(:company) { connector_company }

  def consent_for(user)
    client = register_client
    token = consent_request_token(client['client_id'], pkce_pair.last)
    get '/api/v1/oauth/consent', params: { request: token }, headers: app_headers(user)
    [token, response.parsed_body]
  end

  it 'keeps a role without it from connecting, and says who to ask' do
    rep = connector_user(company, { 'leads' => %w[read] }, connector: nil)
    token, body = consent_for(rep)

    expect(body).to include('can_connect' => false)
    expect(body['blocking_reason']).to include('Ask your admin')

    post '/api/v1/oauth/consent', params: { request: token, decision: 'approve' }, headers: app_headers(rep)
    expect(response).to have_http_status(:forbidden)

    get '/api/v1/connected-apps', headers: app_headers(rep)
    expect(response.parsed_body).to include('can_connect' => false, 'can_allow_changes' => false)
  end

  it 'lets company admins connect with no role setup' do
    admin = connector_user(company, {}, role: 'company_admin')
    _token, body = consent_for(admin)

    expect(body).to include('can_connect' => true, 'can_allow_changes' => true)
  end

  it 'with Read only, connects read only even if changes are requested' do
    reader = connector_user(company, { 'leads' => %w[read update] }, connector: %w[read])
    _token, body = consent_for(reader)
    expect(body).to include('can_connect' => true, 'can_allow_changes' => false)

    tokens = connect!(reader, allow_write: true)
    expect(OauthGrant.last.scope_list).to eq(['mcp:read'])
    names = mcp_post(tokens['access_token'], 'tools/list').dig('result', 'tools').map { |t| t['name'] }
    expect(names).not_to include('create_lead')
  end

  it 'cuts a connected app off on its next request when the role loses Read' do
    rep = connector_user(company, { 'leads' => %w[read] })
    tokens = connect!(rep)
    expect(mcp_post(tokens['access_token'], 'ping')).to include('result' => {})

    RolePermission.where(resource: Resource.find_by!(key: 'ai_connector')).delete_all
    Rails.cache.clear

    body = mcp_post(tokens['access_token'], 'ping')
    expect(response).to have_http_status(:forbidden)
    expect(body.dig('error', 'message')).to include('no longer allows the AI connector')
    expect(response.headers['WWW-Authenticate']).to include('insufficient_scope')
  end

  it 'makes a connected app read only when the role loses Update, without disconnecting it' do
    rep = connector_user(company, { 'leads' => %w[read create] })
    tokens = connect!(rep, allow_write: true)
    update = Action.find_by!(key: 'update')
    RolePermission.where(resource: Resource.find_by!(key: 'ai_connector'), action: update).delete_all
    Rails.cache.clear

    names = mcp_post(tokens['access_token'], 'tools/list').dig('result', 'tools').map { |t| t['name'] }
    expect(names).to include('list_leads')
    expect(names).not_to include('create_lead')
  end

  context 'in a company without RBAC' do
    let(:company) { connector_company(rbac: false) }

    it 'is admins only, since there are no roles to grant it through' do
      staff = company.users.create!(email: "s-#{SecureRandom.hex(3)}@example.com", first_name: 'S', last_name: 'T',
                                    password: 'Pass1234!', role: 'staff', status: 'active')
      admin = company.users.create!(email: "a-#{SecureRandom.hex(3)}@example.com", first_name: 'A', last_name: 'D',
                                    password: 'Pass1234!', role: 'admin', status: 'active')

      expect(consent_for(staff).last).to include('can_connect' => false)
      expect(consent_for(admin).last).to include('can_connect' => true)
    end
  end
end
