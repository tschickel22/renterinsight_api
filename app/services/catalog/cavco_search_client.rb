# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'

module Catalog
  # Thin client for Cavco's Elastic App Search engine, which backs cavcohomes.com
  # and every sibling brand site (palmharbor.com, fleetwoodhomes.com,
  # fairmonthomes.com, solitairehomes.com — all the same platform).
  #
  # WHY AN API RATHER THAN HTML
  # Cavco's pages are a client-side Bloomreach SPA; the served HTML is a ~950
  # byte shell with no data in it. Everything the page shows comes from this
  # engine, so there is no HTML surface to parse. The upside is structured JSON
  # instead of markup scraping — no SKU decoding, no extractor fragility.
  #
  # CREDENTIALS ARE DISCOVERED, NOT HARDCODED
  # The search key is a PUBLIC read-only App Search key that the site ships to
  # every visitor. It is delivered per-page by Bloomreach rather than baked into
  # the JS bundle, so we read it the same way the site does — from
  # /resourceapi/<path> — and cache it. If Cavco rotates the key, the next
  # refresh picks it up instead of the source silently going dark.
  #
  # The engine indexes three document types:
  #   retailer  (1,361) — the dealer directory
  #   floorplan (2,391) — orderable models, scoped by retailer_ids
  #   inventory (5,149) — actual in-stock homes, with prices
  class CavcoSearchClient
    CONFIG_SETTING_KEY = 'cavco_search_config'
    CONFIG_TTL         = 7.days
    DISCOVERY_HOST     = 'https://www.cavcohomes.com'
    # Any real page carries the component config; a retailer directory page is
    # the most stable one to ask for.
    DISCOVERY_PATH     = '/resourceapi/our-retailers/US'
    USER_AGENT         = 'DealerTideBot/1.0 (+https://dealertide.com; catalog sync for Cavco dealers)'
    HTTP_TIMEOUT       = 30
    MAX_PAGE_SIZE      = 100

    class Error < StandardError; end

    def initialize(config: nil)
      @config = config
    end

    # @param filters [Hash] App Search filter object
    # @return [Hash] parsed response
    def search(filters: nil, query: '', page: 1, size: 20, facets: nil, sort: nil)
      body = { 'query' => query.to_s, 'page' => { 'size' => size.clamp(0, MAX_PAGE_SIZE), 'current' => page } }
      body['filters'] = filters if filters.present?
      body['facets']  = facets  if facets.present?
      body['sort']    = sort    if sort.present?

      post(body)
    end

    # Walks every page of a filtered result set. Yields each raw document.
    # `limit` stops early — the admin Test action never needs all 165.
    def each_document(filters:, limit: nil, page_size: MAX_PAGE_SIZE)
      fetched = 0
      page    = 1

      loop do
        size = limit ? [page_size, limit - fetched].min : page_size
        break if size <= 0

        response = search(filters: filters, page: page, size: size)
        results  = Array(response['results'])
        results.each { |doc| yield flatten(doc) }

        fetched += results.size
        total_pages = response.dig('meta', 'page', 'total_pages').to_i
        break if results.empty? || page >= total_pages
        break if limit && fetched >= limit

        page += 1
      end
      fetched
    end

    def total_for(filters)
      search(filters: filters, size: 0).dig('meta', 'page', 'total_results').to_i
    end

    # App Search wraps every value as { "raw" => value }. Unwrap once here so
    # extractors read plain fields.
    def self.flatten(doc)
      doc.each_with_object({}) do |(key, value), out|
        next if key == '_meta'

        out[key] = value.is_a?(Hash) && value.key?('raw') ? value['raw'] : value
      end
    end

    def flatten(doc) = self.class.flatten(doc)

    def config
      @config ||= self.class.resolved_config
    end

    class << self
      # Cached engine config. Refreshed from the site when missing or stale.
      def resolved_config(force: false)
        cached = Setting.get('Platform', PlatformSetting::PLATFORM_SCOPE_ID, CONFIG_SETTING_KEY)
        if !force && cached.is_a?(Hash) && cached['api_key'].present? &&
           cached['fetched_at'].present? && Time.zone.parse(cached['fetched_at']) > CONFIG_TTL.ago
          return cached
        end

        discovered = discover_config
        return cached if discovered.blank? && cached.is_a?(Hash) # keep working on a bad refresh
        raise Error, 'could not discover Cavco search config' if discovered.blank?

        Setting.set('Platform', PlatformSetting::PLATFORM_SCOPE_ID, CONFIG_SETTING_KEY,
                    discovered.merge('fetched_at' => Time.current.utc.iso8601))
        discovered
      end

      # Bloomreach ships component parameters as parallel keys/messages arrays.
      # The block we want carries apiKey + engineName + endpointBase together.
      def discover_config
        body = http_get("#{DISCOVERY_HOST}#{DISCOVERY_PATH}")
        return nil if body.blank?

        json = body.to_s
        json.scan(/"keys"\s*:\s*(\[[^\]]*\])\s*,\s*"messages"\s*:\s*(\[[^\]]*\])/) do |keys_raw, msgs_raw|
          keys = JSON.parse(keys_raw)
          msgs = JSON.parse(msgs_raw)
          pairs = keys.zip(msgs).to_h
          next unless pairs['apiKey'].to_s.start_with?('search-') && pairs['engineName'].present?

          return { 'api_key' => pairs['apiKey'], 'engine' => pairs['engineName'],
                   'endpoint_base' => pairs['endpointBase'] }
        end
        nil
      rescue JSON::ParserError => e
        Rails.logger.warn "[Catalog::CavcoSearchClient] config discovery parse failed: #{e.message}"
        nil
      end

      def http_get(url)
        uri  = URI.parse(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl      = uri.scheme == 'https'
        http.open_timeout = HTTP_TIMEOUT
        http.read_timeout = HTTP_TIMEOUT

        req = Net::HTTP::Get.new(uri.request_uri)
        req['User-Agent'] = USER_AGENT
        req['Accept']     = 'application/json'
        res = http.request(req)
        res.is_a?(Net::HTTPSuccess) ? res.body : nil
      rescue StandardError => e
        Rails.logger.warn "[Catalog::CavcoSearchClient] discovery HTTP error: #{e.class}: #{e.message}"
        nil
      end
    end

    private

    def post(body)
      cfg = config
      raise Error, 'missing Cavco search config' if cfg.blank? || cfg['api_key'].blank?

      uri  = URI.parse("#{cfg['endpoint_base']}/api/as/v1/engines/#{cfg['engine']}/search.json")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl      = true
      http.open_timeout = HTTP_TIMEOUT
      http.read_timeout = HTTP_TIMEOUT

      req = Net::HTTP::Post.new(uri.request_uri)
      req['Authorization'] = "Bearer #{cfg['api_key']}"
      req['Content-Type']  = 'application/json'
      req['User-Agent']    = USER_AGENT
      req.body = body.to_json

      res = http.request(req)
      raise Error, "search failed: HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)

      JSON.parse(res.body)
    rescue JSON::ParserError => e
      raise Error, "unparseable search response: #{e.message}"
    end
  end
end
