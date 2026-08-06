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
      contact = ContactExtractor.new(digests, pages_html: raw_html_cache).call

      profile, schema_warnings, usage = ProfileBuilder.new(
        company: @record.company, user: @record.created_by
      ).call(
        digests:, brand:, links:, integrations:, contact:,
        source_url: @record.source_url,
        # Photographs of homes we already hold, used only if the scan produced
        # no usable hero. Resolved from the same lot the inventory block will
        # render, so the imagery and the listings match.
        inventory_images: InventoryImagery.for_profile(@record)
      )

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

      import_assets
      @record
    rescue StandardError => e
      @record.update!(status: 'failed', error_message: e.message.truncate(500))
      raise
    end

    private

    def collect_digests(root)
      root_digest = PageDigest.new(root).call
      pages = { normalize_url(root.url) || root.url => root }

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

    # Picks the pages worth spending a 10-fetch budget on.
    #
    # Round-robin across roles rather than sorting by role rank. Sorting put all
    # 29 pages that classify as "inventory" ahead of the single /about-us, so a
    # real scan visited six product pages and never saw about, contact or faq —
    # which is why the first run came back with no team and no testimonials.
    # One page per role, then a second of each, and so on.
    def discover(root, root_digest)
      base_host = host_of(root.url)
      candidates = (sitemap_urls(root.url) + root_digest.links.map { |l| l[:href] })
                   .filter_map { |url| normalize_url(url) }
                   .uniq
                   .select { |url| host_of(url) == base_host }

      inventory = LinkInventory.new([root_digest], base_url: root.url).call
      role_by_path = inventory['internal'].to_h { |e| [e['path'], e['page_role']] }

      by_role = candidates.group_by do |url|
        role_by_path[path_of(url)] || 'other'
      end

      interleave(by_role)
    end

    # Take the first of each role in priority order, then the second of each,
    # until the candidates run out. Unknown roles go last but are not dropped —
    # a dealer's best page is sometimes called something we do not recognise.
    def interleave(by_role)
      ordered_roles = ROLE_PRIORITY + (by_role.keys - ROLE_PRIORITY)
      queues = ordered_roles.filter_map { |role| by_role[role]&.dup }

      result = []
      until queues.all?(&:empty?)
        queues.each do |queue|
          url = queue.shift
          result << url if url
        end
      end
      result
    end

    # Trailing slashes and fragments produced duplicates that silently ate
    # three of the ten fetch slots on the first real scan.
    def normalize_url(url)
      uri = URI.parse(url.to_s)
      return nil if uri.host.blank?

      uri.fragment = nil
      # Chomp unconditionally so "/" and "" unify — otherwise the bare domain
      # and the trailing-slash root count as two different pages.
      uri.path = uri.path.to_s.chomp('/')
      uri.to_s
    rescue StandardError
      nil
    end

    def path_of(url)
      path = URI.parse(url).path.to_s.chomp('/')
      path.presence || '/'
    rescue StandardError
      '/'
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

    # Rehost imagery onto our S3 so a preview does not depend on the client's
    # old host staying up. Non-fatal: a scan whose images stayed hotlinked
    # still demos fine, so a failure here is a warning rather than a dead scan.
    def import_assets
      result = AssetImporter.new(@record).call
      report = @record.report.to_h
      report['assets_imported'] = result.imported
      report['assets_skipped'] = result.skipped
      report['warnings'] = (Array(report['warnings']) + result.warnings).uniq
      @record.update!(report: report)
    rescue StandardError => e
      Rails.logger.warn("[SiteProfiles::Orchestrator] asset import failed: #{e.message}")
      @record.update!(
        report: @record.report.to_h.merge(
          'warnings' => (Array(@record.report['warnings']) +
            ['Images could not be copied; the preview links to the original site.']).uniq
        )
      )
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
