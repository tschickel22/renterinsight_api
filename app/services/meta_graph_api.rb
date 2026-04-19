# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'

# Wrapper around the Meta Graph API for Facebook Lead Ads.
# Handles common errors (expired tokens, rate limits, missing objects).
class MetaGraphApi
  API_VERSION = 'v21.0'
  BASE_URL    = "https://graph.facebook.com/#{API_VERSION}"

  class Error < StandardError; end
  class ExpiredTokenError < Error; end
  class RateLimitError < Error; end
  class NotFoundError < Error; end

  # ------------------------------------------------------------------
  # Class-level helpers
  # ------------------------------------------------------------------
  class << self
    # Fetch the full lead data for a Lead Ads leadgen_id.
    def fetch_lead(leadgen_id, access_token)
      get("/#{leadgen_id}", access_token, fields: 'id,created_time,field_data,ad_id,form_id,campaign_id,campaign_name,adset_id,adset_name,ad_name,platform')
    end

    # Exchange a short-lived user access token for a long-lived one.
    def exchange_token(short_lived_token)
      get('/oauth/access_token', nil,
          grant_type:        'fb_exchange_token',
          client_id:         app_id,
          client_secret:     app_secret,
          fb_exchange_token: short_lived_token)
    end

    # Subscribe a page to webhook events (leadgen by default).
    def subscribe_page_to_webhooks(page_id, access_token, subscribed_fields: ['leadgen'])
      post("/#{page_id}/subscribed_apps", access_token,
           subscribed_fields: Array(subscribed_fields).join(','))
    end

    def unsubscribe_page_from_webhooks(page_id, access_token)
      delete("/#{page_id}/subscribed_apps", access_token)
    end

    def get_page_info(page_id, access_token)
      get("/#{page_id}", access_token, fields: 'id,name,link,picture,about,category')
    end

    # List pages the authenticated user manages.
    def list_user_pages(user_access_token)
      get('/me/accounts', user_access_token, fields: 'id,name,access_token,category,tasks')
    end

    # Exchange OAuth code for a user access token.
    def exchange_code_for_token(code, redirect_uri)
      get('/oauth/access_token', nil,
          client_id:     app_id,
          client_secret: app_secret,
          redirect_uri:  redirect_uri,
          code:          code)
    end

    # ------------------------------------------------------------------
    # HTTP primitives
    # ------------------------------------------------------------------
    def get(path, access_token, **params)
      params = params.merge(access_token: access_token) if access_token.present?
      uri    = URI.parse("#{BASE_URL}#{path}")
      uri.query = URI.encode_www_form(params) if params.any?

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
        http.read_timeout = 15
        http.open_timeout = 10
        http.request(Net::HTTP::Get.new(uri))
      end

      handle_response(response)
    end

    def post(path, access_token, **params)
      uri = URI.parse("#{BASE_URL}#{path}")
      req = Net::HTTP::Post.new(uri)
      body = params.merge(access_token: access_token).compact
      req.set_form_data(body)

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
        http.read_timeout = 15
        http.open_timeout = 10
        http.request(req)
      end

      handle_response(response)
    end

    def delete(path, access_token, **params)
      params = params.merge(access_token: access_token) if access_token.present?
      uri    = URI.parse("#{BASE_URL}#{path}")
      uri.query = URI.encode_www_form(params) if params.any?

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
        http.read_timeout = 15
        http.open_timeout = 10
        http.request(Net::HTTP::Delete.new(uri))
      end

      handle_response(response)
    end

    # ------------------------------------------------------------------
    # Error handling
    # ------------------------------------------------------------------
    def handle_response(response)
      body = parse_body(response.body)

      case response.code.to_i
      when 200..299
        body
      when 400..499
        err = body.is_a?(Hash) ? body['error'] : nil
        code    = err&.dig('code')
        subcode = err&.dig('error_subcode')
        msg     = err&.dig('message') || response.body

        if [190, 102, 463].include?(code) || [458, 460, 463, 467].include?(subcode)
          raise ExpiredTokenError, msg
        elsif code == 4 || code == 17 || code == 32 || code == 613
          raise RateLimitError, msg
        elsif response.code.to_i == 404
          raise NotFoundError, msg
        else
          raise Error, "Meta Graph API error (#{code}): #{msg}"
        end
      else
        raise Error, "Meta Graph API error #{response.code}: #{response.body}"
      end
    end

    def parse_body(raw)
      return {} if raw.blank?
      JSON.parse(raw)
    rescue JSON::ParserError
      { 'raw' => raw }
    end

    # ------------------------------------------------------------------
    # Credentials helpers
    # ------------------------------------------------------------------
    def app_id
      Rails.application.credentials.dig(:meta, :app_id) || ENV['META_APP_ID']
    end

    def app_secret
      Rails.application.credentials.dig(:meta, :app_secret) || ENV['META_APP_SECRET']
    end
  end
end
