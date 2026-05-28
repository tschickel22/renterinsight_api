# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'nokogiri'

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
    PDP_BASE_URL = 'https://www.championhomes.com/models'

    DEFAULT_RADIUS    = 200
    PAGE_SIZE         = 12
    MAX_PAGES         = 50  # Safety cap: 50 pages * 12 = 600 homes max
    REQUEST_TIMEOUT   = 30  # seconds
    PDP_FETCH_DELAY   = 0.5 # seconds — polite spacing for sequential PDP fetches
    USER_AGENT        = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' \
                        '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

    # URL patterns used to classify media found in PDP HTML.
    SCENE7_IMG_REGEX   = %r{https?://s7d9\.scene7\.com/is/image/championhomes/[^\s"'<>)]+}i
    MATTERPORT_REGEX   = %r{https?://(?:my\.)?matterport\.com/show/\?[^\s"'<>)]*m=[A-Za-z0-9]+[^\s"'<>)]*}i
    YOUTUBE_EMBED_REGEX = %r{https?://(?:www\.)?youtube(?:-nocookie)?\.com/embed/[A-Za-z0-9_-]+(?:\?[^\s"'<>)]*)?}i

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
      body = http_get(url, accept: 'application/json')
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

    # Fetches a Champion PDP (Product Detail Page) and extracts the full media
    # set: gallery photos, Matterport tour, YouTube walkthrough, elevation
    # renderings, and floor plans. The IMS feed only carries a 4-image carousel
    # subset, while the PDP carries 40+ gallery shots plus the rich media.
    #
    # Resilient by design — Champion's HTML structure may shift without notice.
    # On any error (HTTP failure, parse error, unexpected DOM) this returns an
    # empty result so sync continues with whatever the feed already provided.
    #
    # Includes a PDP_FETCH_DELAY sleep before each request so back-to-back
    # calls from the sync loop don't hammer Champion's CDN.
    #
    # @param slug [String] Champion home slug, e.g., 'embrace-space-233'
    # @return [Hash] {
    #   gallery:       [String, ...],   # ordered list of gallery image URLs
    #   matterport_url: String | nil,
    #   video_url:     String | nil,    # YouTube embed URL
    #   elevations:    [String, ...],   # exterior rendering URLs
    #   floor_plans:   [String, ...]    # floor-plan image URLs
    # }
    def fetch_pdp_media(slug)
      empty = { gallery: [], matterport_url: nil, video_url: nil, elevations: [], floor_plans: [] }
      return empty if slug.to_s.strip.empty?

      sleep(PDP_FETCH_DELAY)

      url = "#{PDP_BASE_URL}/#{slug}"
      html = http_get(url, accept: 'text/html,application/xhtml+xml')
      return empty if html.nil?

      extract_pdp_media(html, slug)
    rescue StandardError => e
      Rails.logger.warn "[ChampionImsClient] PDP scrape failed for slug=#{slug}: #{e.class}: #{e.message}"
      empty
    end

    private

    # Extract the media buckets from a Champion PDP HTML body. Public-ish only
    # for testability; not part of the documented API.
    def extract_pdp_media(html, slug = nil)
      doc = Nokogiri::HTML(html)

      # Build slug fragments for filtering model-specific images.
      # Champion's naming: "233-embrace-space-233-kitchen-1" contains the slug
      # (with hyphens). We also check partial matches for slugs that get
      # truncated in the asset name.
      slug_fragments = []
      if slug.present?
        slug_clean = slug.to_s.strip.downcase
        slug_fragments << slug_clean
        # Also try without leading numbers: "embrace-space-233" from "233-embrace-space-233"
        # And the short form without series number prefix
        parts = slug_clean.split('-')
        slug_fragments << parts.drop(1).join('-') if parts.size > 2
        # Drop trailing numeric suffixes for broader matching
        slug_fragments << parts[0...-1].join('-') if parts.last =~ /^\d+$/
        slug_fragments.reject!(&:blank?)
        slug_fragments.uniq!
      end

      # Phase 1: Walk <img> tags with their alt text. Alt text is the most
      # reliable signal for floor-plan / elevation classification.
      classified  = {} # url => :gallery | :elevation | :floor_plan
      alt_for_url = {} # url => first alt text we saw

      doc.css('img').each do |img|
        src = first_attr(img, %w[src data-src data-original data-lazy-src])
        next if src.blank?
        next unless src.match?(SCENE7_IMG_REGEX)

        normalized = src.match(SCENE7_IMG_REGEX).to_s
        next unless model_specific_url?(normalized, slug_fragments)

        alt        = img['alt'].to_s
        alt_for_url[normalized] ||= alt
        classified[normalized] ||= classify_scene7(normalized, alt)
      end

      # Phase 2: Sweep the raw HTML for scene7 URLs that didn't appear as <img>
      # tags — e.g., URLs inside JSON config blobs or lazy-loaded JS state.
      html.scan(SCENE7_IMG_REGEX) do |match|
        url = match.to_s
        next unless model_specific_url?(url, slug_fragments)
        classified[url] ||= classify_scene7(url, alt_for_url[url].to_s)
      end

      gallery     = classified.select { |_, kind| kind == :gallery }.keys
      elevations  = classified.select { |_, kind| kind == :elevation }.keys
      floor_plans = classified.select { |_, kind| kind == :floor_plan }.keys

      matterport_url = extract_first_match(doc, html, MATTERPORT_REGEX)
      video_url      = extract_first_match(doc, html, YOUTUBE_EMBED_REGEX)

      {
        gallery:        gallery,
        matterport_url: matterport_url,
        video_url:      video_url,
        elevations:     elevations,
        floor_plans:    floor_plans
      }
    end

    # Champion's URL conventions (observed):
    #   - "-standard" in the asset path marks floor-plan layouts
    #   - "floor" or "floorplan" in path/alt marks floor plans
    #   - "elevation" or "exterior-rendering" in path/alt marks elevation art
    #   - everything else is a gallery photo
    def classify_scene7(url, alt)
      haystack = "#{url} #{alt}".downcase
      return :floor_plan if haystack.include?('floorplan') || haystack.include?('floor plan') || haystack.include?('floor-plan')
      return :floor_plan if url.downcase.include?('-standard')
      return :floor_plan if alt.to_s.downcase.include?('floor')
      return :elevation  if haystack.include?('elevation') || haystack.include?('exterior-rendering') || haystack.include?('exterior rendering')
      :gallery
    end

    # Returns true if the Scene7 URL's asset path contains a slug fragment,
    # meaning it belongs to THIS model — not a nav banner, blog thumbnail,
    # promo card, or another model on the page.
    def model_specific_url?(url, slug_fragments)
      return true if slug_fragments.empty? # no slug to filter by → accept all

      # Extract the asset name from the Scene7 URL:
      # https://s7d9.scene7.com/is/image/championhomes/233-embrace-space-233-kitchen-1
      # → "233-embrace-space-233-kitchen-1"
      asset_part = url.to_s.split('/championhomes/').last.to_s.split('?').first.to_s.downcase
      # URL-decode for names with %20 etc.
      asset_part = URI.decode_www_form_component(asset_part) rescue asset_part

      slug_fragments.any? { |frag| asset_part.include?(frag) }
    end

    def first_attr(node, names)
      names.each do |n|
        v = node[n]
        return v if v.present?
      end
      nil
    end

    # Look first at iframes/anchors via Nokogiri (cheap, ordered), then fall
    # back to a regex scan of the raw HTML so we still catch URLs embedded
    # in inline JSON/JS that Nokogiri can't reach as attributes.
    def extract_first_match(doc, html, regex)
      doc.css('iframe[src], a[href], link[href]').each do |node|
        candidate = node['src'] || node['href']
        next if candidate.blank?
        m = candidate.match(regex)
        return m.to_s if m
      end
      m = html.match(regex)
      m&.to_s
    end

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

    def http_get(url, accept: 'application/json')
      uri = URI.parse(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl     = (uri.scheme == 'https')
      http.open_timeout = REQUEST_TIMEOUT
      http.read_timeout = REQUEST_TIMEOUT

      request = Net::HTTP::Get.new(uri.request_uri)
      request['User-Agent'] = USER_AGENT
      request['Referer']    = "https://www.championhomes.com/ims-plp/#{navision_id}"
      request['Accept']     = accept

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
