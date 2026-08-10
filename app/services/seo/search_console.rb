# frozen_string_literal: true

require 'net/http'

module Seo
  # What Google actually did with a page, rather than what we think of it.
  #
  # Everything else in this area is our own opinion: SeoAudit grades markup,
  # RichResultRules says whether it qualifies. Neither can tell you whether
  # Google indexed the page, when it last looked, or whether it saw the rich
  # result we emitted. Only Search Console knows that, and the URL Inspection
  # API is the one supported way to ask.
  #
  # Deliberately limited to sites we host. The API answers only for properties
  # the owner has verified, which is fine for a dealer site on our own
  # infrastructure and impossible for a prospect's. Prospect scanning stays with
  # SeoAudit, which needs nobody's permission.
  #
  # NOT VERIFIED AGAINST THE LIVE API. This was written against Google's
  # documented request and response shapes, with no OAuth client and no verified
  # property to exercise it. The parsing below is specced against those shapes;
  # the handshake is not. Treat the first live run as the real test, and see
  # SETUP for what has to exist before it can happen.
  #
  # SETUP
  #   1. A Google Cloud OAuth client with the Search Console API enabled.
  #   2. GOOGLE_OAUTH_CLIENT_ID / GOOGLE_OAUTH_CLIENT_SECRET, which the mail
  #      integration already reads, plus a refresh token for an account that can
  #      see the properties.
  #   3. Each dealer domain verified in Search Console. We control both the DNS
  #      and the served HTML for tenant sites, so either method works.
  #   4. SEARCH_CONSOLE_REFRESH_TOKEN in the environment.
  module SearchConsole
    INSPECT_URL = 'https://searchconsole.googleapis.com/v1/urlInspection/index:inspect'
    TOKEN_URL = 'https://oauth2.googleapis.com/token'
    SCOPE = 'https://www.googleapis.com/auth/webmasters.readonly'

    # Google's own daily quota is per property and generous for our purposes,
    # but a dealer with a thousand homes would still blow through it, so callers
    # sample rather than sweep.
    DEFAULT_SAMPLE = 10

    # What we keep from a much larger response. Everything here answers a
    # question a dealer would actually ask.
    Result = Struct.new(:url, :indexed, :coverage_state, :last_crawled_at,
                        :rich_results, :rich_result_issues, :error, keyword_init: true) do
      def indexed?
        indexed.present?
      end

      def ok?
        error.blank?
      end

      def to_h
        { 'url' => url, 'indexed' => indexed, 'coverage_state' => coverage_state,
          'last_crawled_at' => last_crawled_at, 'rich_results' => rich_results,
          'rich_result_issues' => rich_result_issues, 'error' => error }.compact
      end
    end

    module_function

    # @param site_url [String] the verified property, e.g. "https://dealer.com/"
    # @param page_urls [Array<String>] pages to ask about
    # @param token [String, nil] an access token; fetched when omitted
    # @param http [#post] injected so this is testable without the network
    # @return [Array<Result>]
    def inspect_urls(site_url:, page_urls:, token: nil, http: nil)
      access = token || access_token
      return [Result.new(error: 'no Search Console credentials configured')] if access.blank?

      Array(page_urls).first(DEFAULT_SAMPLE).map do |page_url|
        inspect_one(site_url: site_url, page_url: page_url, token: access, http: http)
      end
    end

    def inspect_one(site_url:, page_url:, token:, http: nil)
      body = { inspectionUrl: page_url, siteUrl: site_url }.to_json
      response = (http || method(:post_json)).call(INSPECT_URL, body, token)

      parse(page_url, response)
    rescue StandardError => e
      Rails.logger.warn("[Seo::SearchConsole] #{page_url}: #{e.class}: #{e.message}")
      Result.new(url: page_url, error: e.message)
    end

    # Google nests the interesting part three levels down, and answers with a
    # 200 and an "error" object often enough that a status check alone is not
    # enough to know it worked.
    def parse(page_url, response)
      data = response.is_a?(Hash) ? response : (JSON.parse(response.to_s) rescue {})
      return Result.new(url: page_url, error: data.dig('error', 'message') || 'unreadable response') if
        data['error'].present?

      index = data.dig('inspectionResult', 'indexStatusResult') || {}
      rich = Array(data.dig('inspectionResult', 'richResultsResult', 'detectedItems'))

      Result.new(
        url: page_url,
        indexed: index['verdict'].to_s == 'PASS',
        coverage_state: index['coverageState'],
        last_crawled_at: index['lastCrawlTime'],
        rich_results: rich.filter_map { |item| item['richResultType'] }.uniq,
        # Issues are nested per detected item, and a severity of ERROR is what
        # actually costs the result.
        rich_result_issues: rich.flat_map do |item|
          Array(item['items']).flat_map do |detail|
            Array(detail['issues']).select { |i| i['severity'].to_s == 'ERROR' }
                                   .filter_map { |i| i['issueMessage'] }
          end
        end.uniq
      )
    end

    # Same client credentials the mail integration already uses, so a dealer
    # never configures Google twice.
    def access_token(http: nil)
      refresh = ENV['SEARCH_CONSOLE_REFRESH_TOKEN'].presence
      return nil if refresh.blank?

      client_id = ENV['GOOGLE_OAUTH_CLIENT_ID'].presence ||
                  Rails.application.credentials.dig(:oauth, :google, :client_id)
      client_secret = ENV['GOOGLE_OAUTH_CLIENT_SECRET'].presence ||
                      Rails.application.credentials.dig(:oauth, :google, :client_secret)
      return nil if client_id.blank? || client_secret.blank?

      tokens = (http || method(:post_form)).call(
        TOKEN_URL,
        { client_id: client_id, client_secret: client_secret,
          refresh_token: refresh, grant_type: 'refresh_token', scope: SCOPE }
      )
      tokens = JSON.parse(tokens.to_s) unless tokens.is_a?(Hash)
      tokens['access_token'].presence
    rescue StandardError => e
      Rails.logger.warn("[Seo::SearchConsole] token: #{e.class}: #{e.message}")
      nil
    end

    def post_json(url, body, token)
      uri = URI(url)
      request = Net::HTTP::Post.new(uri)
      request['Authorization'] = "Bearer #{token}"
      request['Content-Type'] = 'application/json'
      request.body = body

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 20) do |h|
        h.request(request)
      end
      JSON.parse(response.body.to_s)
    end

    def post_form(url, form)
      uri = URI(url)
      request = Net::HTTP::Post.new(uri)
      request.set_form_data(form)

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 20) do |h|
        h.request(request)
      end
      JSON.parse(response.body.to_s)
    end
  end
end
