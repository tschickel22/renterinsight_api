# frozen_string_literal: true

module Oauth
  # GET /oauth/authorize, opened in the user's browser by the AI app.
  #
  # This app has no server-side session (the React app holds a JWT), so the
  # request is validated here and handed to the React consent page as a signed
  # token. That page runs inside the normal login, MFA included, and posts the
  # user's decision to Api::V1::OauthConsentsController, which issues the code.
  class AuthorizationsController < BaseController
    def show
      auth = AuthorizationRequest.from_params(oauth_params, request: request)
      redirect_to Config.consent_url(auth.signed), allow_other_host: true
    rescue AuthorizationRequest::Untrusted => e
      # Never redirect to an unverified URI with an error: show it instead.
      render plain: "#{Brand.current.name} could not start this connection: #{e.message}", status: :bad_request
    rescue AuthorizationRequest::Redirectable => e
      redirect_to AuthorizationRequest.redirect_with(
        e.redirect_uri,
        error: e.code, error_description: e.message, state: e.state, iss: Config.issuer(request)
      ), allow_other_host: true
    end
  end
end
