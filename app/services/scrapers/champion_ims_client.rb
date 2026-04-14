# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'

module Scrapers
  # Client for the Champion Homes Inventory Management System (IMS) public feed.
  #
  # The IMS feed is a public JSON endpoint served from championhomes.com. It
  # returns a paginated list of manufactured homes available through a specific
  # retailer (identified by their Navision ID, e.g., "0551KS").
  #
  # Endpoint (reverse-engineered from the championhomes.com JS clientlib):
  #   https://www.championhomes.com/content/championhomes/us/en/ims-plp/jcr:content/
  #   root/container/container/container_copy/homecardlist.find-a-home-ims.json
  #     ?RetailerNavisionId=0551KS
  #     &Radius=200
  #     &pagination-limit=12
  #     &pagination-page=1
  #
  # Required headers:
  #   User-Agent: browser string (the CDN rejects non-browser UAs)
  #   Referer:    https://www.championhomes.com/ims-plp/<NAVISION_ID>
  #
  # No authentication. The feed is public.
  #
  # Usage:
  #   client = Scrapers::ChampionImsClient.new(navision_id: '0551KS')
  #   homes  = client.fetch_all   # => [Hash, Hash, ...]
  class ChampionImsClient
    BASE_URL = 'https://www.championhomes.com/content/championhomes/us/en/ims-plp/jcr:content/root/container/container/container_copy/homecardlist.find-a-home-ims.json'

    DEFAULT_RADIUS    = 200
    PAGE_SIZE         = 12
    MAX_PAGES         = 50  # Safety cap: 50 pages * 12 = 600 homes max
    REQUEST_TIMEOUT   = 30  # seconds
    USER_AGENT        = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' \
                        '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

    attr_reader :navision_id, :radius

    def initialize(navision_id:, radius: DEFAULT_RADIUS)
      @navision_id = navision_id.to_s.strip.upcase
      @radius      = radius
    end

    # Fetches all pages sequentially and returns a flat array of home hashes.
    # Stops when a page returns zero items or when MAX_PAGES is reached.
    #
    # @return [Array<Hash>] raw home records from the feed
    def fetch_all
      all_homes = []
      page = 1

      loop do
        if page > MAX_PAGES
          Rails.logger.warn "[ChampionImsClient] Reached MAX_PAGES (#{MAX_PAGES}) for #{navision_id}, stopping"
          break
        end

        page_items = fetch_page(page)

        if page_items.nil? || page_items.empty?
          Rails.logger.info "[ChampionImsClient] No more items at page #{page}, stopping (total: #{all_homes.size})"
          break
        end

        all_homes.concat(page_items)
        Rails.logger.info "[ChampionImsClient] Page #{page} for #{navision_id}: #{page_items.size} items (running total: #{all_homes.size})"

        # Stop early if we got a partial page (last page by definition)
        break if page_items.size < PAGE_SIZE

        page += 1
      end

      Rails.logger.info "[ChampionImsClient] Fetched #{all_homes.size} total homes for #{navision_id}"
      all_homes
    end

    # Fetches a single page of results.
    #
    # @param page_num [Integer] 1-based page number
    # @return [Array<Hash>, nil] array of home hashes, or nil on error
    def fetch_page(page_num)
      url = build_url(page_num)
      body = http_get(url)
      return nil if body.nil?

      parsed = JSON.parse(body)
      extract_items(parsed)
    rescue JSON::ParserError => e
      Rails.logger.error "[ChampionImsClient] JSON parse error for #{navision_id} page #{page_num}: #{e.message}"
      nil
    rescue StandardError => e
      Rails.logger.error "[ChampionImsClient] Unexpected error for #{navision_id} page #{page_num}: #{e.class}: #{e.message}"
      nil
    end

    private

    def build_url(page_num)
      params = {
        'RetailerNavisionId'  => navision_id,
        'Radius'              => radius.to_s,
        'pagination-limit'    => PAGE_SIZE.to_s,
        'pagination-page'     => page_num.to_s
      }
      query = URI.encode_www_form(params)
      "#{BASE_URL}?#{query}"
    end

    def http_get(url)
      uri = URI.parse(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl     = (uri.scheme == 'https')
      http.open_timeout = REQUEST_TIMEOUT
      http.read_timeout = REQUEST_TIMEOUT

      request = Net::HTTP::Get.new(uri.request_uri)
      request['User-Agent'] = USER_AGENT
      request['Referer']    = "https://www.championhomes.com/ims-plp/#{navision_id}"
      request['Accept']     = 'application/json'

      response = http.request(request)

      case response
      when Net::HTTPSuccess
        response.body
      else
        Rails.logger.error "[ChampionImsClient] HTTP #{response.code} for #{url}: #{response.message}"
        nil
      end
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      Rails.logger.error "[ChampionImsClient] Timeout fetching #{url}: #{e.message}"
      nil
    rescue SocketError, Errno::ECONNREFUSED => e
      Rails.logger.error "[ChampionImsClient] Network error fetching #{url}: #{e.message}"
      nil
    end

    # Champion's response shape varies slightly across their AEM deployment.
    # Common shapes:
    #   { "items" => [...], "totalResults" => N }
    #   { "homes" => [...] }
    #   { "results" => [...] }
    #   [...] (top-level array - rare but possible)
    #
    # This method tries each shape in order and returns the first array found.
    def extract_items(parsed)
      return parsed if parsed.is_a?(Array)
      return nil unless parsed.is_a?(Hash)

      %w[items homes results data].each do |key|
        value = parsed[key]
        return value if value.is_a?(Array)
      end

      # Last-ditch: if the hash has exactly one array value, use it.
      array_values = parsed.values.select { |v| v.is_a?(Array) }
      return array_values.first if array_values.size == 1

      Rails.logger.warn "[ChampionImsClient] Could not locate items in response. Keys: #{parsed.keys.inspect}"
      nil
    end
  end
end
