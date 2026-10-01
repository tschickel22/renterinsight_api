# frozen_string_literal: true

require 'rails_helper'
require_relative '../../support/mcp_connector_helpers'

# What the Claude connector directory checks before listing a server
# (claude.com/docs/connectors/building/submission and .../authentication).
# Fails the moment a tool ships without a title or honest safety hints, or
# the OAuth handshake drifts from what Claude expects.
RSpec.describe 'Claude directory readiness', :mcp, type: :request do
  all_tools = McpController::READ_TOOLS + McpController::WRITE_TOOLS

  describe 'tool annotations' do
    all_tools.each do |tool|
      it "#{tool.name_value} has a title and explicit safety hints" do
        h = tool.to_h
        expect(h[:title]).to be_present
        expect(h.dig(:annotations, :title)).to eq(h[:title])
        expect(h.dig(:annotations, :readOnlyHint)).to be_in([true, false])
        expect(h.dig(:annotations, :destructiveHint)).to be_in([true, false])
        expect(h.dig(:_meta, 'securitySchemes')).to be_present
      end
    end

    it 'marks every read tool read only and every write tool not' do
      expect(McpController::READ_TOOLS.map { |t| t.to_h.dig(:annotations, :readOnlyHint) }).to all(be(true))
      expect(McpController::WRITE_TOOLS.map { |t| t.to_h.dig(:annotations, :readOnlyHint) }).to all(be(false))
    end

    # destructiveHint false promises the tool only ADDS. Anything that changes
    # existing data must say so.
    it 'marks the tools that change existing data as destructive' do
      destructive = McpController::WRITE_TOOLS.select { |t| t.to_h.dig(:annotations, :destructiveHint) }.map(&:name_value)
      expect(destructive).to contain_exactly('update_lead_status', 'assign_lead', 'update_deal_stage',
                                             'update_workflow_draft', 'enroll_in_nurture')
      expect(McpTools::EnrollInNurture.to_h.dig(:annotations, :openWorldHint)).to be(true)
    end
  end

  describe 'OAuth as Claude uses it' do
    before { seed_rbac! }

    it 'answers an unauthenticated call with 401 and the metadata pointer (Claude ignores it on 200)' do
      post '/mcp', params: { jsonrpc: '2.0', id: 1, method: 'initialize' }.to_json,
                   headers: { 'CONTENT_TYPE' => 'application/json' }

      expect(response).to have_http_status(:unauthorized)
      expect(response.headers['WWW-Authenticate']).to include('resource_metadata=')
    end

    it "accepts Claude's hosted callback and loopback callbacks on any port, localhost or 127.0.0.1" do
      register_client(redirect: 'https://claude.ai/api/mcp/auth_callback')
      expect(response).to have_http_status(:created)

      client = register_client(redirect: 'http://localhost/callback')
      _verifier, challenge = pkce_pair
      %w[http://localhost:33418/callback http://127.0.0.1:61022/callback].each do |uri|
        get '/oauth/authorize', params: authorize_params(client['client_id'], challenge, redirect: uri)
        expect(response.location).to include('/oauth/consent?request='), uri
      end
    end

    it 'takes a form-encoded token request' do
      tokens = connect!(connector_user(connector_company, { 'leads' => %w[read] }))
      expect(tokens).to include('access_token', 'refresh_token', 'token_type' => 'Bearer')
      expect(request.content_type).to start_with('application/x-www-form-urlencoded')
    end
  end
end
