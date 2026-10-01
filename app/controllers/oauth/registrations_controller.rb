# frozen_string_literal: true

module Oauth
  # RFC 7591 dynamic client registration. Deprecated by MCP 2026-07-28 in
  # favour of Client ID Metadata Documents but still what many clients send,
  # Claude Code and older ChatGPT connectors among them.
  #
  # Every client is public (no secret). Registration grants nothing by itself;
  # see OauthClient. The redirect allowlist is what stops a lookalike app.
  class RegistrationsController < BaseController
    PER_IP_PER_HOUR = 30

    def create
      if OauthClient.where(registered_ip: request.remote_ip, created_at: 1.hour.ago..).count >= PER_IP_PER_HOUR
        raise Error.new('invalid_request', 'Too many registrations from this address. Try again later.', status: 429)
      end

      body = oauth_params
      grant_types = Array(body[:grant_types].presence || %w[authorization_code refresh_token])
      unless (grant_types - %w[authorization_code refresh_token]).empty?
        raise Error.new('invalid_client_metadata', 'Only authorization_code and refresh_token are supported')
      end

      client = OauthClient.new(
        client_id: "dtc_#{SecureRandom.urlsafe_base64(24)}",
        client_name: body[:client_name].to_s.strip.first(100).presence || 'AI app',
        redirect_uris: Array(body[:redirect_uris]).map(&:to_s),
        registration_type: 'dcr',
        client_uri: body[:client_uri].to_s.first(500).presence,
        logo_uri: body[:logo_uri].to_s.first(500).presence,
        metadata: body.slice(:software_id, :software_version).to_h,
        registered_ip: request.remote_ip
      )
      unless client.save
        code = client.errors.key?(:redirect_uris) ? 'invalid_redirect_uri' : 'invalid_client_metadata'
        raise Error.new(code, client.errors.full_messages.to_sentence)
      end

      response.set_header('Cache-Control', 'no-store')
      render status: :created, json: {
        client_id: client.client_id,
        client_id_issued_at: client.created_at.to_i,
        client_name: client.client_name,
        redirect_uris: client.redirect_uris,
        grant_types: %w[authorization_code refresh_token],
        response_types: ['code'],
        token_endpoint_auth_method: 'none',
        client_uri: client.client_uri,
        logo_uri: client.logo_uri
      }.compact
    end
  end
end
