# frozen_string_literal: true

module Oauth
  # The OAuth authorization server the MCP connector signs in through. Called
  # by Claude's and ChatGPT's servers and by the user's browser, never with an
  # app JWT, so it sits outside ApplicationController's auth chain entirely.
  class BaseController < ActionController::API
    rescue_from Oauth::Error do |e|
      response.set_header('Cache-Control', 'no-store')
      render json: e.as_json, status: e.status
    end

    private

    def oauth_params
      params.permit!.to_h.with_indifferent_access.except(:controller, :action, :format)
    end
  end
end
