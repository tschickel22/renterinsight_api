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
      # Whether any page in this scan had to come from the Wayback Machine.
      # Recorded on the report because it is the usual explanation for a scan
      # that read one page, and for imagery that could not be rehosted.
      @from_archive = false
      # How many pages had to be loaded in a browser. Worth knowing per scan:
      # it is the difference between a site we can read cheaply and one that
      # costs a rendering credit per page.
      @rendered_pages = 0
    end

    def call
      @record.update!(status: 'fetching')

      root = @fetcher.get(@record.source_url)
      # Not "Could not load <url>". By the time the fetch returns nothing we
      # have already tried the wire, a browser and the archive, and we know
      # which of them refused us — a bare "could not load" throws that away and
      # leaves an admin with nothing to act on. Reported from production, where
      # it was the only thing a failed scan said.
      raise Fetcher::FetchError, unreadable_message(nil) if root.nil?

      @from_archive = root.try(:from_archive?).present?
      @rendered_pages += 1 if root.try(:rendered?)

      robots_allowed = @fetcher.robots_allows?(@record.source_url)
      @warnings << 'robots.txt disallows crawling this site; scanned anyway at admin request.' unless robots_allowed

      digests = collect_digests(root)
      raise Fetcher::FetchError, 'No readable pages found.' if digests.empty?

      ensure_site_was_actually_read!(digests, root)

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
      ensure_lead_form
      suggest_subdomain
      run_seo_audit(root)
      @record
    rescue StandardError => e
      @record.update!(
        status: 'failed',
        error_message: e.message.truncate(500),
        # The kind, not the prose. A site refusing this server is the one
        # failure another machine can fix, and the admin screen offers that
        # route — which it cannot do by matching on a sentence.
        report: @record.report.to_h.merge('failure_kind' => render_verdict.to_s.presence)
      )
      raise
    ensure
      # However the scan ended, the browser goes with it. Chrome runs in the
      # same container as Puma here, so one leaked process is one the box keeps
      # paying for until it restarts.
      @fetcher.try(:close)
    end

    private

    # Words below which a page is a shell, not a site.
    #
    # Measured against the digest, not the raw HTML, since that is all the rest
    # of the pipeline ever sees. Vercel's security checkpoint digests to 3
    # words and the parked-domain stub to 0, while a dealer home page with a
    # hero and two short paragraphs clears 60 without trying. Set well above the
    # first pair and well below the last: a thin but real page must still scan.
    MIN_READABLE_WORDS = 60

    # Refuse to build a demo out of a page that is not the dealer's site.
    #
    # A bot wall answers every request, so a scan can "succeed" having read
    # nothing. Measured on thehomeplus.com: the live site returns Vercel's
    # security checkpoint to any non-browser agent, and the only copy the Wayback
    # Machine holds is a 114-byte parked redirect. Both parse as valid HTML and
    # neither is the dealership. Left alone we built a Content Profile out of the
    # stub, graded THAT 36 out of 100 "across 1 page", and put the number in
    # front of the prospect as an audit of their website , with no logo, no
    # copy and no second page, because there was never anything to read.
    #
    # Failing loudly here costs an admin one message. The alternative costs them
    # a meeting.
    def ensure_site_was_actually_read!(digests, root)
      return if digests.any? { |d| readable_words(d) >= MIN_READABLE_WORDS }

      raise Fetcher::FetchError, unreadable_message(root)
    end

    def readable_words(digest)
      [
        digest.title.to_s,
        Array(digest.headings).map { |h| h[:text] || h['text'] }.join(' '),
        Array(digest.paragraphs).join(' ')
      ].join(' ').split(/\s+/).count { |w| w.present? }
    end

    # Name the actual failure.
    #
    # The first version of this message offered "usually a bot check or a site
    # whose text is drawn entirely by JavaScript" , a guess covering four
    # different failures that want four different fixes, and it sent us looking
    # in the wrong place. The renderer knows which one happened; say it.
    FALLBACK = 'Upload a brochure or build the demo by hand instead.'

    # What to do next, which is not the same for every failure.
    #
    # A site that refuses this server is not a dead end: the same scan run from
    # a laptop on an ordinary connection reads it in seconds, and that route
    # exists. Telling someone to upload a brochure instead — or naming an
    # environment variable at them — buries the one thing that works.
    LOCAL_SCAN_ADVICE = <<~TEXT.squish
      It will scan from a computer that can open the site: run
      rake "site_scan:push[URL]" there. Otherwise upload a brochure or build the
      demo by hand.
    TEXT

    def unreadable_message(root)
      host = host_of(@record.source_url) || @record.source_url
      advice = render_verdict == :still_challenged ? LOCAL_SCAN_ADVICE : FALLBACK
      "#{host} #{unreadable_reason(root)} #{advice}"
    end

    def unreadable_reason(root)
      # The renderer's verdict comes FIRST, and the archive is a footnote to it.
      #
      # This was the other way round for one deploy, on the reasoning that a
      # placeholder in the archive is its own answer. It is not: reaching the
      # archive at all means the live site refused us AND the browser failed,
      # and which of those failed is the only actionable fact here. Ordering it
      # second hid exactly the diagnosis this message was added to deliver, and
      # cost a deploy to find out.
      [live_site_reason(root), archive_note(root)].compact.join(', and ') + '.'
    end

    def live_site_reason(root)
      case render_verdict
      when :off
        'could not be read, and rendering is switched off, so a site that needs a ' \
          'browser cannot be scanned. Set SITE_SCAN_RENDERER=chrome'
      when :unavailable
        'could not be read, and the browser that would have rendered it failed to ' \
          "start on this server#{render_detail}"
      when :still_challenged
        'is behind a bot check that will not clear for this server' \
          "#{render_detail}. It is refusing this machine rather than the browser" \
          "#{hosted_renderer_hint}"
      when :error, :empty
        "could not be read: the browser did not return a page#{render_detail}"
      when :rendered
        'loaded in a browser but never drew any content , its text is built by ' \
          'JavaScript that did not finish'
      else
        # No verdict at all: the renderer was never reached, so the wire is all
        # we tried.
        root.nil? ? 'could not be loaded at all' : 'refused our request'
      end
    end

    # Measured, not guessed: the same site clears in a tenth of a second from a
    # home connection with the same browser build, and never in two minutes from
    # here. Waiting longer or changing browsers does not fix an address that is
    # being refused, and only one thing does.
    def hosted_renderer_hint
      return '' if Renderer.hosted_configured?

      ', and no wait or browser setting changes that'
    end

    def archive_note(root)
      return nil unless root.try(:from_archive?).present?

      'the web archive holds only a placeholder copy of it, so there was nothing to read'
    end

    # The verdict on the page the scan was actually built from.
    def render_verdict
      notes = @fetcher.try(:render_notes) || {}
      notes[@record.source_url] || notes.values.first
    end

    def render_detail
      details = @fetcher.try(:render_details) || {}
      detail = details[@record.source_url] || details.values.compact.first
      detail.present? ? " (#{detail})" : ''
    end

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
        @from_archive ||= response.try(:from_archive?).present?
        @rendered_pages += 1 if response.try(:rendered?)
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
      # allow_render: false — XML, not a page. A browser would return its own
      # rendering of the tree rather than the document.
      response = @fetcher.get(URI.join("#{uri.scheme}://#{uri.host}", '/sitemap.xml').to_s,
                              allow_render: false)
      return [] if response.nil?

      Nokogiri::XML(response.body).css('url > loc').map(&:text).first(50)
    rescue StandardError
      []
    end

    # BrandExtractor works off raw HTML (CSS custom properties, style tags),
    # which the digest deliberately strips — so it gets the bodies separately.
    # Looked up by the SAME key the cache was written with.
    #
    # raw_html_cache is keyed by normalize_url, which chomps the trailing slash,
    # while a digest carries the response URL, which keeps it — and keeps the
    # host it was redirected to. So every lookup missed, BrandExtractor received
    # an empty page list, and no scan has ever produced a logo.
    #
    # Measured on a real profile: source https://mobilehomemasters.com/,
    # first page scanned https://www.mobilehomemasters.com/, cache key
    # https://www.mobilehomemasters.com. The site's logo was sitting in the
    # markup all along with "logo" in its filename.
    #
    # ContactExtractor was unaffected because it takes the whole cache rather
    # than looking pages up by key, which is why phone and email came through
    # while the logo never did.
    def pages_for_brand(digests)
      digests.map { |d| { url: d.url, html: raw_html_cache[normalize_url(d.url) || d.url] } }
             .select { |p| p[:html].present? }
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

    # A demo with "Contact form not available" where the contact form belongs is
    # not a demo anyone is persuaded by. Runs once the profile is ready, against
    # the lot that will actually back the preview — the public intake endpoint
    # scopes the form to that company, so it has to be that one.
    #
    # Non-fatal: a scan that produced a profile is worth keeping either way.
    # The address this demo would get if it became a real site.
    #
    # Derived from the scanned brand name, which is the dealer's own trading
    # name and therefore what they would want in the URL — far better than the
    # site name someone types into the commit dialog in a hurry.
    #
    # Recorded now so a platform admin can correct it while it is still a demo.
    # After commit the site belongs to the dealer and renaming its address
    # breaks whatever has already been shared.
    # Grades the site we just read. Always runs: the admin decides afterwards
    # whether the prospect sees it, and that decision needs the findings in hand.
    #
    # Non-fatal by design. A demo without a gap report is still a demo, so an
    # audit failure must not turn a completed scan into a failed one.
    def run_seo_audit(root)
      report = SeoAudit.new(
        source_url: @record.source_url,
        pages_html: raw_html_cache,
        fetcher: @fetcher,
        from_archive: root.try(:from_archive?).present?
      ).call

      @record.update!(seo_report: report)
    rescue StandardError => e
      Rails.logger.warn("[SiteProfiles::Orchestrator] seo audit failed: #{e.message}")
    end

    def suggest_subdomain
      name = @record.profile.dig('brand', 'name').presence || @record.display_name.presence
      return if name.blank?

      suggestion = Websites::SubdomainSuggester.suggest(name)
      @record.update!(suggested_subdomain: suggestion) if suggestion.present?
    rescue StandardError => e
      Rails.logger.warn("[SiteProfiles::Orchestrator] subdomain suggestion failed: #{e.message}")
    end

    def ensure_lead_form
      config = DemoInventoryResolver.config_for_profile(@record)
      return if config.blank?

      company = Company.find_by(id: config['company_id'])
      Websites::DefaultLeadForm.ensure_for(company)
    rescue StandardError => e
      Rails.logger.warn("[SiteProfiles::Orchestrator] lead form setup failed: #{e.message}")
    end

    def build_report(digests, integrations, links)
      {
        'pages_scanned' => digests.map(&:url),
        'page_count' => digests.size,
        # Why a scan came back with one page is otherwise invisible to the admin
        # looking at "1 pages scanned" and wondering which of the site's twenty
        # we picked. Every page we tried and could not read is already in
        # @warnings; this is the count beside it.
        'pages_unreadable' => @warnings.count { |w| w.start_with?('Could not read') },
        'from_archive' => @from_archive,
        'pages_rendered' => @rendered_pages,
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
