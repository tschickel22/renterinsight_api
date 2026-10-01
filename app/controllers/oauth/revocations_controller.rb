# frozen_string_literal: true

module Oauth
  # RFC 7009. Always 200, whether or not the token existed, so the endpoint
  # cannot be used to test tokens. Revoking a refresh token disconnects the
  # whole grant, which is what an app's "disconnect" button means.
  class RevocationsController < BaseController
    def create
      digest = OauthToken.digest(params[:token])
      token = OauthToken.find_by(token_digest: digest) if params[:token].present?
      if token
        token.kind == 'refresh' ? token.oauth_grant.revoke! : token.update_columns(revoked_at: Time.current)
      end
      head :ok
    end
  end
end
