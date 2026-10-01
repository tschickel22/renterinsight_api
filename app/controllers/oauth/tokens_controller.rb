# frozen_string_literal: true

module Oauth
  # POST /oauth/token. Public clients only, so PKCE (for codes) and rotation
  # (for refresh tokens) are what prove the caller is the app that started.
  class TokensController < BaseController
    def create
      response.set_header('Cache-Control', 'no-store')
      response.set_header('Pragma', 'no-cache')
      body = oauth_params

      tokens = case body[:grant_type]
               when 'authorization_code' then exchange_code(body)
               when 'refresh_token' then refresh(body)
               else raise Error.new('unsupported_grant_type', 'Use authorization_code or refresh_token')
               end

      render json: { token_type: 'Bearer' }.merge(tokens)
    end

    private

    def exchange_code(body)
      client = ClientResolver.find!(body[:client_id])
      code = OauthAuthorizationCode.find_by(code_digest: OauthAuthorizationCode.digest(body[:code]))
      raise Error.new('invalid_grant', 'Unknown authorization code') unless code

      grant = code.oauth_grant
      raise Error.new('invalid_grant', 'Code was issued to another client') unless grant.oauth_client_id == client.id

      # A code presented twice means it leaked. Revoke everything it produced
      # (OAuth 2.1 section 4.1.3).
      if code.used_at
        grant.revoke!
        raise Error.new('invalid_grant', 'Authorization code was already used')
      end
      raise Error.new('invalid_grant', 'Authorization code expired') if code.expired?
      raise Error.new('invalid_grant', 'redirect_uri does not match') if body[:redirect_uri].present? && body[:redirect_uri] != code.redirect_uri
      raise Error.new('invalid_grant', 'PKCE verification failed') unless code.verifier_matches?(body[:code_verifier])
      raise Error.new('invalid_target', 'Tokens are only issued for this MCP server') unless Config.resource_matches?(body[:resource], request)

      ensure_usable!(grant)

      # Single use even under a race: only one request can flip used_at.
      claimed = OauthAuthorizationCode.where(id: code.id, used_at: nil).update_all(used_at: Time.current)
      raise Error.new('invalid_grant', 'Authorization code was already used') if claimed.zero?

      OauthToken.issue_pair!(grant: grant, scopes: code.scopes.split)
    end

    def refresh(body)
      client = ClientResolver.find!(body[:client_id])
      token = OauthToken.find_by_plaintext(body[:refresh_token], kind: 'refresh')
      raise Error.new('invalid_grant', 'Unknown refresh token') unless token

      grant = token.oauth_grant
      raise Error.new('invalid_grant', 'Refresh token was issued to another client') unless grant.oauth_client_id == client.id

      # Rotation: a refresh token that was already exchanged is being replayed,
      # so whoever holds the chain is not trusted any more.
      if token.used_at
        grant.revoke!
        raise Error.new('invalid_grant', 'Refresh token was already used')
      end
      raise Error.new('invalid_grant', 'Refresh token expired or revoked') unless token.usable?

      # Check access BEFORE spending the refresh token. Spending it first meant
      # a refusal (role without AI Connector, add-on off) also burned it, so
      # once access was restored the app could not refresh and had to make the
      # person sign in again.
      ensure_usable!(grant)

      claimed = OauthToken.where(id: token.id, used_at: nil).update_all(used_at: Time.current)
      raise Error.new('invalid_grant', 'Refresh token was already used') if claimed.zero?

      # A refresh can narrow scope but never widen it.
      scopes = body[:scope].present? ? (body[:scope].to_s.split & token.scope_list) : token.scope_list
      OauthToken.issue_pair!(grant: grant, scopes: scopes.presence || token.scope_list)
    end

    def ensure_usable!(grant)
      reason = AccessPolicy.denial_reason(grant)
      raise Error.new('invalid_grant', reason) if reason
    end
  end
end
