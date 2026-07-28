# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'

# Wrapper around the Meta Graph API for Facebook Lead Ads.
# Handles common errors (expired tokens, rate limits, missing objects).
class MetaGraphApi
  API_VERSION = 'v21.0'
  BASE_URL    = "https://graph.facebook.com/#{API_VERSION}"

  # Carries Meta's structured fields, not just a sentence — callers need the
  # subcode to tell an app-configuration gate (which the user must clear in the
  # Meta dashboard) from a bad parameter (which is our bug).
  class Error < StandardError
    attr_reader :code, :subcode, :user_title, :user_msg

    def initialize(message = nil, code: nil, subcode: nil, user_title: nil, user_msg: nil)
      super(message)
      @code       = code
      @subcode    = subcode
      @user_title = user_title
      @user_msg   = user_msg
    end
  end

  class ExpiredTokenError < Error; end
  class RateLimitError < Error; end
  class NotFoundError < Error; end

  # Meta rejects ad creatives from an app that hasn't passed App Review.
  DEV_MODE_SUBCODE = 1_885_183

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

    # Publish a post to a Facebook Page. Photo-posts take precedence (higher
    # engagement); if a photo_url is provided we use /photos, otherwise /feed.
    def publish_page_post(page_id, access_token, message:, link: nil, photo_url: nil)
      if photo_url.present?
        post("/#{page_id}/photos", access_token,
             caption: message,
             url:     photo_url)
      elsif link.present?
        post("/#{page_id}/feed", access_token,
             message: message,
             link:    link)
      else
        post("/#{page_id}/feed", access_token, message: message)
      end
    end

    # Publish to an Instagram Business Account. Two-step: create media
    # container, then publish. Instagram always requires an image.
    def publish_instagram_post(ig_user_id, access_token, caption:, image_url:)
      container = post("/#{ig_user_id}/media", access_token,
                       caption:   caption,
                       image_url: image_url)
      container_id = container['id']
      return nil if container_id.blank?

      post("/#{ig_user_id}/media_publish", access_token, creation_id: container_id)
    end

    def get_post_insights(post_id, access_token)
      get("/#{post_id}/insights", access_token,
          metric: 'post_impressions,post_reach,post_clicks,post_engaged_users')
    end

    def get_post_basic_metrics(post_id, access_token)
      get("/#{post_id}", access_token,
          fields: 'id,message,created_time,likes.summary(true),comments.summary(true),shares')
    end

    # ------------------------------------------------------------------
    # Comments
    # ------------------------------------------------------------------
    def get_post_comments(post_id, access_token, limit: 50)
      get("/#{post_id}/comments", access_token,
          fields: 'id,message,from{id,name,picture},created_time,parent{id},comment_count',
          limit:  limit,
          order:  'reverse_chronological')
    end

    def reply_to_comment(comment_id, access_token, message:)
      post("/#{comment_id}/comments", access_token, message: message)
    end

    def delete_comment(comment_id, access_token)
      delete("/#{comment_id}", access_token)
    end

    def hide_comment(comment_id, access_token)
      post("/#{comment_id}", access_token, is_hidden: true)
    end

    def unhide_comment(comment_id, access_token)
      post("/#{comment_id}", access_token, is_hidden: false)
    end

    # ------------------------------------------------------------------
    # Ads / Marketing API
    # ------------------------------------------------------------------
    def get_ad_campaigns(ad_account_id, access_token)
      get("/act_#{ad_account_id}/campaigns", access_token,
          fields: 'id,name,objective,status,daily_budget,lifetime_budget,start_time,stop_time,' \
                  'insights{spend,impressions,clicks,reach}',
          limit:  100)
    end

    # Ad sets inside a campaign, for attaching a new creative to an existing one
    # rather than spinning up a fresh campaign per ad.
    def get_ad_sets(campaign_id, access_token)
      get("/#{campaign_id}/adsets", access_token,
          fields: 'id,name,status,daily_budget,lifetime_budget,optimization_goal,billing_event',
          limit:  100)
    end

    def get_campaign_insights(campaign_id, access_token, date_preset: 'last_30d')
      get("/#{campaign_id}/insights", access_token,
          fields:      'spend,impressions,clicks,reach,actions,cost_per_action_type',
          date_preset: date_preset)
    end

    def create_campaign(ad_account_id, access_token, name:, objective:, status: 'PAUSED', daily_budget_cents: nil,
                        special_ad_categories: [], bid_strategy: 'LOWEST_COST_WITHOUT_CAP')
      params = {
        name:                  name,
        objective:             objective,
        status:                status,
        special_ad_categories: Array(special_ad_categories).to_json
      }
      # bid_strategy only belongs here when the budget does. Setting it on a
      # campaign with no budget earns "No Budget for Campaign — add a budget to
      # edit the bid strategy"; with ad-set budgets the strategy rides on the
      # ad set instead.
      params[:bid_strategy] = bid_strategy if daily_budget_cents && bid_strategy
      if daily_budget_cents
        params[:daily_budget] = daily_budget_cents
      else
        # Budget lives on the ad set. Meta then demands an explicit answer on
        # whether ad sets may pool 20% of their budgets, and rejects the whole
        # campaign if the field is absent. false = each ad set keeps its own.
        params[:is_adset_budget_sharing_enabled] = false
      end

      post("/act_#{ad_account_id}/campaigns", access_token, **params)
    end

    def create_ad_set(ad_account_id, access_token, campaign_id:, name:, daily_budget_cents:, targeting:,
                      billing_event: 'IMPRESSIONS', optimization_goal: 'LEAD_GENERATION', start_time: nil,
                      end_time: nil, promoted_object: nil, bid_strategy: 'LOWEST_COST_WITHOUT_CAP')
      params = {
        campaign_id:       campaign_id,
        name:              name,
        daily_budget:      daily_budget_cents,
        billing_event:     billing_event,
        optimization_goal: optimization_goal,
        # The budget lives here, so the bid strategy does too.
        # LOWEST_COST_WITHOUT_CAP is "most results for the budget" — the only
        # strategy that needs no bid cap or ROAS floor from us.
        bid_strategy:      bid_strategy,
        targeting:         targeting.to_json,
        start_time:        start_time || Time.current.iso8601,
        status:            'PAUSED'
      }
      # Without an end_time a daily-budget ad set runs until manually paused —
      # the wizard's "3 days / $27 total" would quietly keep spending.
      params[:end_time]        = end_time if end_time.present?
      params[:promoted_object] = promoted_object.to_json if promoted_object.present?

      post("/act_#{ad_account_id}/adsets", access_token, **params)
    end

    def create_ad(ad_account_id, access_token, ad_set_id:, name:, creative_id:)
      post("/act_#{ad_account_id}/ads", access_token,
           adset_id:    ad_set_id,
           name:        name,
           creative_id: creative_id,
           status:      'PAUSED')
    end

    def create_ad_creative(ad_account_id, access_token, page_id:, message:, link:, image_url: nil,
                           headline: nil, description: nil, call_to_action_type: 'LEARN_MORE',
                           lead_form_id: nil)
      cta = { type: call_to_action_type }
      # When we attach a native FB Lead Form, Meta requires the form id to live
      # inside call_to_action.value.lead_gen_form_id.
      if lead_form_id.present?
        cta[:value] = { lead_gen_form_id: lead_form_id }
      end

      link_data = {
        message:        message,
        link:           link,
        name:           headline,
        description:    description,
        call_to_action: cta
      }.compact
      link_data[:picture] = image_url if image_url.present?

      object_story_spec = { page_id: page_id, link_data: link_data }

      post("/act_#{ad_account_id}/adcreatives", access_token,
           name:              "RI_Creative_#{Time.current.to_i}",
           object_story_spec: object_story_spec.to_json)
    end

    def update_campaign_status(campaign_id, access_token, status:)
      post("/#{campaign_id}", access_token, status: status)
    end

    def delete_campaign(campaign_id, access_token)
      post("/#{campaign_id}", access_token, status: 'DELETED')
    end

    def get_ad_account_info(ad_account_id, access_token)
      get("/act_#{ad_account_id}", access_token,
          fields: 'id,name,account_status,currency,timezone_name,amount_spent')
    end

    def get_user_ad_accounts(user_access_token)
      # `business` names the owning portfolio. Without it an unnamed account
      # renders as its bare id ("47496870"), which is indistinguishable from
      # any other account when a user has several.
      get('/me/adaccounts', user_access_token,
          fields: 'id,account_id,name,account_status,currency,business{id,name}',
          limit:  100)
    end

    # Resolve a free-text interest to Meta's own targeting ids. flexible_spec
    # rejects name-only entries, so without this an interest can't be targeted
    # at all — it has to be looked up first.
    def search_ad_interests(query, access_token, limit: 5)
      get('/search', access_token,
          type:  'adinterest',
          q:     query,
          limit: limit)
    end

    def get_lead_forms(page_id, access_token)
      get("/#{page_id}/leadgen_forms", access_token,
          fields: 'id,name,status,created_time,leads_count',
          limit:  50)
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
        err     = body.is_a?(Hash) ? body['error'] : nil
        code    = err&.dig('code')
        subcode = err&.dig('error_subcode')

        # Log the whole payload — the useful detail (which field Meta objected
        # to) never fits in a toast, but we need it when diagnosing.
        Rails.logger.error "[MetaGraphApi] #{response.code} #{response.body.to_s.truncate(2000)}"

        msg = error_message_for(err, response)

        details = {
          code:       code,
          subcode:    subcode,
          user_title: err.is_a?(Hash) ? err['error_user_title'] : nil,
          user_msg:   err.is_a?(Hash) ? err['error_user_msg'] : nil
        }

        if [190, 102, 463].include?(code) || [458, 460, 463, 467].include?(subcode)
          raise ExpiredTokenError.new(msg, **details)
        elsif code == 4 || code == 17 || code == 32 || code == 613
          raise RateLimitError.new(msg, **details)
        elsif response.code.to_i == 404
          raise NotFoundError.new(msg, **details)
        else
          raise Error.new("Meta Graph API error (#{code}): #{msg}", **details)
        end
      else
        Rails.logger.error "[MetaGraphApi] #{response.code} #{response.body.to_s.truncate(2000)}"
        raise Error, "Meta returned an unexpected #{response.code} response."
      end
    end

    # Meta's `message` is often just "Invalid parameter". The actionable detail
    # lives in error_user_msg and error_data.blame_field_specs, which name the
    # field it objected to — so fold those in rather than making the user guess.
    def error_message_for(err, response)
      unless err.is_a?(Hash)
        # Not a Graph error at all: Meta serves an HTML error page for some
        # failures. Dumping that page into the UI is worse than useless.
        return "Meta returned an unreadable #{response.code} response " \
               '(often an ad account the connected user cannot access).'
      end

      parts = []
      parts << err['error_user_title'].presence
      parts << err['error_user_msg'].presence
      parts << err['message'].presence if parts.compact.empty?

      blamed = blame_fields(err['error_data'])
      parts << "Field: #{blamed.join(', ')}" if blamed.any?

      parts.compact.join(' — ').presence || "HTTP #{response.code}"
    end

    # error_data comes back as a Hash on some errors and as a JSON *string* on
    # others. Treating it as one shape crashed the error handler itself, which
    # turned a readable Meta rejection into a 500 and "Unable to launch ad".
    def blame_fields(error_data)
      data = error_data.is_a?(String) ? (JSON.parse(error_data) rescue nil) : error_data
      return [] unless data.is_a?(Hash)

      Array(data['blame_field_specs']).flatten.compact.uniq
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
