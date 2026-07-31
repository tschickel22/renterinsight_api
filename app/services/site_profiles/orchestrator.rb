# frozen_string_literal: true

module SiteProfiles
  # Runs a scan end to end and writes the result onto a SiteContentProfile.
  #
  # One bad page must never kill a scan — a dealer site with a broken /about is
  # still worth importing — so page-level failures become warnings in the report
  # and the run continues.
  class Orchestrator
    MAX_PAGES = 10

    # Which page roles are worth spending a fetch on, best first.
    ROLE_PRIORITY = %w[home inventory about financing contact services land gallery faq].freeze

    def initialize(profile_record, fetcher: Fetcher.new)
      @record = profile_record
      @fetcher = fetcher
      @warnings = []
    end

    def call
      @record.update!(status: 'fetching')

      root = @fetcher.get(@record.source_url)
      raise Fetcher::FetchError, "Could not load #{@record.source_url}" if root.nil?

      robots_allowed = @fetcher.robots_allows?(@record.source_url)
      @warnings << 'robots.txt disallows crawling this site; scanned anyway at admin request.' unless robots_allowed

      digests = collect_digests(root)
      raise Fetcher::FetchError, 'No readable pages found.' if digests.empty?

      @record.update!(status: 'extracting')

      brand = BrandExtractor.new(pages_for_brand(digests)).call
      links = LinkInventory.new(digests, base_url: @record.source_url).call
      integrations = VendorDetector.new(digests, source_host: host_of(@record.source_url)).call

      profile, schema_warnings, usage = ProfileBuilder.new(
        company: @record.company, user: @record.created_by
      ).call(digests:, brand:, links:, integrations:, source_url: @record.source_url)

      @warnings.concat(schema_warnings)

      @record.update!(
        status: 'ready',
        profile: profile,
        schema_version: ProfileSchema::VERSION,
        robots_allowed: robots_allowed,
        model_version: usage[:model_version],
        input_tokens: usage[:input_tokens],
        output_tokens: usage[:output_tokens],
        report: build_report(digests, integrations, links)
      )
      @record
    rescue StandardError => e
      @record.update!(status: 'failed', error_message: e.message.truncate(500))
      raise
    end

    private

    def collect_digests(root)
      root_digest = PageDigest.new(root).call
      pages = { root.url => root }

      discover(root, root_digest).each do |url|
        break if pages.size >= MAX_PAGES
        next if pages.key?(url)

        response = @fetcher.get(url)
        if response.nil? || !response.html?
          @warnings << "Could not read #{url}."
          next
        end
        pages[url] = response
      end

      # Keep the raw bodies: BrandExtractor reads CSS custom properties and
      # style tags, which PageDigest deliberately strips.
      pages.each { |url, response| raw_html_cache[url] = response.body }

      pages.values.filter_map do |response|
        response.url == root.url ? root_digest : PageDigest.new(response).call
      rescue StandardError => e
        @warnings << "Could not parse #{response.url}: #{e.message.truncate(120)}"
        nil
      end
    end

    # sitemap.xml first, then same-origin nav links, prioritised by role so a
    # 10-page budget is spent on the pages that carry content.
    def discover(root, root_digest)
      base_host = host_of(root.url)
      from_sitemap = sitemap_urls(root.url)
      from_links = root_digest.links.map { |l| l[:href] }

      candidates = (from_sitemap + from_links).uniq.select do |url|
        host_of(url) == base_host
      end

      inventory = LinkInventory.new([root_digest], base_url: root.url).call
      role_by_path = inventory['internal'].to_h { |e| [e['path'], e['page_role']] }

      candidates.sort_by do |url|
        path = begin
          URI.parse(url).path.to_s.chomp('/')
        rescue StandardError
          ''
        end
        ROLE_PRIORITY.index(role_by_path[path.presence || '/']) || ROLE_PRIORITY.size
      end
    end

    def sitemap_urls(base)
      uri = URI.parse(base)
      response = @fetcher.get(URI.join("#{uri.scheme}://#{uri.host}", '/sitemap.xml').to_s)
      return [] if response.nil?

      Nokogiri::XML(response.body).css('url > loc').map(&:text).first(50)
    rescue StandardError
      []
    end

    # BrandExtractor works off raw HTML (CSS custom properties, style tags),
    # which the digest deliberately strips — so it gets the bodies separately.
    def pages_for_brand(digests)
      digests.map { |d| { url: d.url, html: raw_html_cache[d.url] } }.select { |p| p[:html].present? }
    end

    def raw_html_cache
      @raw_html_cache ||= {}
    end

    def build_report(digests, integrations, links)
      {
        'pages_scanned' => digests.map(&:url),
        'page_count' => digests.size,
        'integrations' => integrations.map do |i|
          { 'vendor' => i.vendor, 'category' => i.category, 'disposition' => i.disposition }
        end,
        'internal_links' => links['internal'].size,
        'external_links' => links['external'].size,
        'warnings' => @warnings.uniq
      }
    end

    def host_of(url)
      URI.parse(url.to_s).host
    rescue StandardError
      nil
    end
  end
end
