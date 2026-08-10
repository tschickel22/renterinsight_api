# frozen_string_literal: true

module SiteProfiles
  # Grades a scanned site on the things that decide whether it gets found.
  #
  # This is a sales artifact before it is a diagnostic. A prospect being shown a
  # replacement demo can be shown, on the same screen, what their current site is
  # missing. So every finding has to be specific and checkable ("6 pages have no
  # meta description" with the URLs), never advice. A dealer can forward a list
  # of URLs to whoever built their site; they cannot forward "improve your SEO".
  #
  # The checks are the ones that separated a Trove-built site from a typical
  # dealer site when both were measured, which is also why LOCAL_BUSINESS and
  # BREADCRUMB are in here: the competitor is missing them too, so a site of ours
  # that emits them beats the best thing in the market rather than merely
  # catching up.
  #
  # Runs off the HTML the scan already fetched. No second crawl.
  class SeoAudit
    SEVERITY_ORDER = { 'fail' => 0, 'warn' => 1, 'pass' => 2 }.freeze

    # Said in the report itself, because a number with no stated basis invites
    # more trust than it has earned. Deliberately names the limits: a reader who
    # discovers them later stops believing the parts that were true.
    SCORE_EXPLAINER = <<~TEXT.squish
      This score measures how well a website is built for search engines and AI
      assistants to read: whether each page describes itself, whether homes and
      the dealership are marked up in a form Google can use, and whether the
      site can be crawled at all. It is our own rubric, not a Google ranking,
      and it does not measure content quality, backlinks, reviews or how a site
      currently ranks. A high score does not guarantee traffic. What it does
      show is whether the technical foundation is in place, which is the part
      most dealer websites get wrong and the part that has to be right before
      anything else works.
    TEXT

    # A phone-sized viewport is the single most consequential tag on this list:
    # Google indexes the mobile page, and without it the desktop layout is what
    # gets judged.
    MIN_WORDS_PER_PAGE = 150
    HEAVY_PAGE_BYTES = 600_000

    # Below this a title gets truncated in results; above it, wasted.
    TITLE_MIN = 15
    TITLE_MAX = 65
    DESCRIPTION_MIN = 70
    DESCRIPTION_MAX = 160

    Check = Struct.new(:key, :label, :status, :headline, :detail, :urls, :weight,
                       keyword_init: true) do
      def to_h
        {
          'key' => key, 'label' => label, 'status' => status,
          'headline' => headline, 'detail' => detail,
          'urls' => Array(urls).first(12), 'weight' => weight
        }
      end
    end

    # @param source_url [String] the site audited
    # @param pages_html [Hash<String, String>] url => raw HTML, from the scan
    # @param fetcher [Fetcher] for robots.txt and sitemap.xml only
    # @param from_archive [Boolean] whether the scan had to read an archived copy
    def initialize(source_url:, pages_html:, fetcher: Fetcher.new, from_archive: false)
      @source_url = source_url.to_s
      @pages_html = pages_html.to_h.reject { |_, html| html.blank? }
      @fetcher = fetcher
      @from_archive = from_archive
    end

    def call
      return empty_report if @pages_html.empty?

      checks = [
        structured_data_check,
        rich_result_check,
        local_business_check,
        breadcrumb_check,
        title_check,
        description_check,
        canonical_check,
        heading_check,
        social_preview_check,
        image_alt_check,
        mobile_viewport_check,
        thin_content_check,
        render_blocking_check,
        page_weight_check,
        mixed_content_check,
        language_check,
        robots_check,
        sitemap_check,
        crawlability_check
      ].compact

      {
        'generated_at' => Time.current.iso8601,
        'source_url' => @source_url,
        'domain' => domain,
        'pages_checked' => @pages_html.size,
        'from_archive' => @from_archive,
        'score' => score(checks),
        'score_explainer' => SCORE_EXPLAINER,
        'gap_count' => checks.count { |c| c.status != 'pass' },
        'checks' => checks.sort_by { |c| [SEVERITY_ORDER.fetch(c.status, 3), -c.weight.to_i] }
                          .map(&:to_h)
      }
    end

    private

    def empty_report
      {
        'generated_at' => Time.current.iso8601, 'source_url' => @source_url,
        'domain' => domain, 'pages_checked' => 0, 'from_archive' => @from_archive,
        'score' => nil, 'score_explainer' => SCORE_EXPLAINER, 'gap_count' => 0, 'checks' => []
      }
    end

    def domain
      URI.parse(@source_url).host.to_s.sub(/\Awww\./, '')
    rescue StandardError
      @source_url
    end

    def docs
      @docs ||= @pages_html.transform_values { |html| Nokogiri::HTML(html) }
    end

    # Every schema.org @type present anywhere on the site.
    def schema_types
      @schema_types ||= docs.each_with_object(Hash.new { |h, k| h[k] = [] }) do |(url, doc), acc|
        doc.css('script[type="application/ld+json"]').each do |node|
          parsed = begin
            JSON.parse(node.text.to_s)
          rescue JSON::ParserError
            next
          end

          Array.wrap(parsed).each do |item|
            next unless item.is_a?(Hash)

            Array.wrap(item['@type']).each { |type| acc[type.to_s] << url }
            # @graph is how many CMSs nest their types, and ignoring it would
            # report a well-marked-up site as having none.
            Array.wrap(item['@graph']).each do |nested|
              next unless nested.is_a?(Hash)

              Array.wrap(nested['@type']).each { |type| acc[type.to_s] << url }
            end
          end
        end
      end
    end

    def structured_data_check
      types = schema_types.keys
      product = types.grep(/\A(Product|Offer|House|SingleFamilyResidence|Accommodation)\z/)

      if types.empty?
        fail_check('structured_data', 'Product structured data', 10,
                   'No structured data at all',
                   'Search engines and AI assistants read schema.org markup to understand what ' \
                   'a page is selling. Without it, listings cannot appear as rich results and ' \
                   'are far less likely to be quoted by ChatGPT or Google AI Overviews.')
      elsif product.empty?
        warn_check('structured_data', 'Product structured data', 10,
                   "Schema present (#{types.uniq.first(4).join(', ')}) but no product markup",
                   'Homes are not individually described, so price, availability and condition ' \
                   'are invisible to search engines even though they are on the page.')
      else
        pass_check('structured_data', 'Product structured data', 10,
                   "#{product.uniq.join(', ')} markup found")
      end
    end

    # The check a dealer feels most directly: local pack placement.
    # Present is not the same as eligible.
    #
    # structured_data_check asks whether a Product node exists. Google asks
    # whether it carries a price, and answers "no rich result" when it does not.
    # We measured a live site where our audit said the markup was there and
    # Google's Rich Results Test said the page was ineligible, which is the gap
    # this closes. There is no API for that tool, so Seo::RichResultRules
    # encodes its documented requirements instead.
    #
    # Only blocking requirements are reported. A finding that fires on something
    # every competent site omits is the one a prospect checks personally.
    def rich_result_check
      blocking = schema_nodes.filter_map do |url, nodes|
        found = Seo::RichResultRules.issues_for(nodes).select(&:required?)
        [url, found] if found.any?
      end
      return nil if schema_nodes.values.flatten.empty?

      if blocking.empty?
        return pass_check('rich_results', 'Rich result eligibility', 8,
                          'The markup qualifies for the results it describes')
      end

      worst = blocking.flat_map(&:last).first
      warn_check('rich_results', 'Rich result eligibility', 8,
                 "#{blocking.size} #{pluralize_pages(blocking.size)} with markup that cannot earn a result",
                 "The page is marked up but incomplete, so #{worst.consequence}.",
                 blocking.map(&:first))
    end

    # Nodes rather than type names, since eligibility is about what is inside a
    # node rather than which nodes exist.
    def schema_nodes
      @schema_nodes ||= docs.each_with_object({}) do |(url, doc), acc|
        acc[url] = doc.css('script[type="application/ld+json"]').flat_map do |node|
          parsed = begin
            JSON.parse(node.text.to_s)
          rescue JSON::ParserError
            next []
          end

          Seo::RichResultRules.nodes_from(parsed)
        end
      end
    end

    def local_business_check
      local = schema_types.keys.grep(/LocalBusiness|HomeGoodsStore|Store|Organization|AutoDealer/)

      if local.empty?
        fail_check('local_business', 'Local business markup', 9,
                   'No local business markup',
                   'Nothing on the site tells Google this is a dealership at a physical address ' \
                   'with hours and a service area, which is what map and local results are built ' \
                   'from. This is missing on competitor-built sites too.')
      else
        pass_check('local_business', 'Local business markup', 9, "#{local.uniq.join(', ')} found")
      end
    end

    def breadcrumb_check
      return pass_check('breadcrumbs', 'Breadcrumb markup', 4, 'BreadcrumbList found') if
        schema_types.key?('BreadcrumbList')

      warn_check('breadcrumbs', 'Breadcrumb markup', 4,
                 'No breadcrumb markup',
                 'Breadcrumbs replace the raw URL in search results with a readable trail, which ' \
                 'measurably improves click-through.')
    end

    def title_check
      missing = []
      problems = []
      seen = Hash.new { |h, k| h[k] = [] }

      docs.each do |url, doc|
        # at_css('title'), not 'head > title': on a large real page Nokogiri
        # reparented the head and the direct-child selector matched nothing, so
        # a page with a perfectly good title was reported as having none.
        title = doc.at_css('title')&.text.to_s.strip
        if title.blank?
          missing << url
          next
        end

        seen[title.downcase] << url
        problems << url if title.length < TITLE_MIN || title.length > TITLE_MAX
      end

      duplicated = seen.select { |_, urls| urls.size > 1 }

      if missing.any?
        fail_check('titles', 'Page titles', 8,
                   "#{missing.size} #{pluralize_pages(missing.size)} with no title tag",
                   'The title is the clickable headline in search results. A page without one is ' \
                   'titled by the search engine, usually badly.', missing)
      elsif duplicated.any?
        warn_check('titles', 'Page titles', 8,
                   "#{duplicated.size} duplicated #{duplicated.size == 1 ? 'title' : 'titles'}",
                   'Pages sharing a title compete with each other and search engines pick one, ' \
                   'often not the one that should rank.', duplicated.values.flatten)
      elsif problems.any?
        warn_check('titles', 'Page titles', 8,
                   "#{problems.size} #{pluralize_pages(problems.size)} with an off-length title",
                   "Titles outside roughly #{TITLE_MIN} to #{TITLE_MAX} characters get truncated " \
                   'in results or waste the space.', problems)
      else
        pass_check('titles', 'Page titles', 8, 'Every page has a usable title')
      end
    end

    def description_check
      missing = docs.reject { |_, doc| meta_content(doc, 'description').present? }.keys
      short = docs.select do |_, doc|
        text = meta_content(doc, 'description')
        text.present? && text.length < DESCRIPTION_MIN
      end.keys

      if missing.any?
        fail_check('descriptions', 'Meta descriptions', 7,
                   "#{missing.size} #{pluralize_pages(missing.size)} with no meta description",
                   'The description is the sales pitch under the link in search results. Without ' \
                   'one, the engine grabs whatever text it finds first.', missing)
      elsif short.any?
        warn_check('descriptions', 'Meta descriptions', 7,
                   "#{short.size} #{pluralize_pages(short.size)} with a very short description",
                   "Under #{DESCRIPTION_MIN} characters leaves most of the result space unused.",
                   short)
      else
        pass_check('descriptions', 'Meta descriptions', 7, 'Every page has a meta description')
      end
    end

    def canonical_check
      missing = docs.reject { |_, doc| doc.at_css('link[rel="canonical"]') }.keys

      if missing.any?
        warn_check('canonical', 'Canonical tags', 6,
                   "#{missing.size} #{pluralize_pages(missing.size)} with no canonical tag",
                   'Canonical tags stop filtered and tracked versions of a page from being ' \
                   'indexed as duplicates, which splits ranking between them.', missing)
      else
        pass_check('canonical', 'Canonical tags', 6, 'Every page declares a canonical URL')
      end
    end

    def heading_check
      none = []
      many = []

      docs.each do |url, doc|
        count = doc.css('h1').size
        none << url if count.zero?
        many << url if count > 1
      end

      if none.any?
        warn_check('headings', 'Page headings', 5,
                   "#{none.size} #{pluralize_pages(none.size)} with no H1",
                   'The H1 is the strongest on-page signal of what a page is about.', none)
      elsif many.any?
        warn_check('headings', 'Page headings', 5,
                   "#{many.size} #{pluralize_pages(many.size)} with more than one H1",
                   'Multiple H1s split the topic signal.', many)
      else
        pass_check('headings', 'Page headings', 5, 'Every page has exactly one H1')
      end
    end

    def social_preview_check
      missing = docs.reject do |_, doc|
        doc.at_css('meta[property="og:image"]') && doc.at_css('meta[property="og:title"]')
      end.keys

      if missing.any?
        warn_check('social_preview', 'Social sharing previews', 5,
                   "#{missing.size} #{pluralize_pages(missing.size)} without a share preview",
                   'Open Graph tags decide what appears when a page is shared to Facebook or ' \
                   'sent in a text. Without them a link posts as bare text and gets ignored.',
                   missing)
      else
        pass_check('social_preview', 'Social sharing previews', 5, 'Share previews are set up')
      end
    end

    def image_alt_check
      total = 0
      without = 0

      docs.each_value do |doc|
        doc.css('img').each do |img|
          total += 1
          without += 1 if img['alt'].to_s.strip.blank?
        end
      end

      return nil if total.zero?

      share = (without.to_f / total * 100).round

      if share >= 40
        warn_check('image_alt', 'Image alt text', 4,
                   "#{share}% of images have no alt text (#{without} of #{total})",
                   'Alt text is how image search reads a photo, and it is also the accessibility ' \
                   'requirement most likely to appear in a complaint.')
      else
        pass_check('image_alt', 'Image alt text', 4,
                   "#{100 - share}% of images describe themselves")
      end
    end

    # Google indexes the mobile version of a page. Without this tag it renders
    # the desktop layout at phone width and judges that.
    def mobile_viewport_check
      missing = docs.reject { |_, doc| doc.at_css("meta[name='viewport']") }.keys
      return pass_check('mobile_viewport', 'Mobile viewport', 7, 'Every page declares a mobile viewport') if missing.empty?

      fail_check('mobile_viewport', 'Mobile viewport', 7,
                 "#{missing.size} #{pluralize_pages(missing.size)} with no mobile viewport tag",
                 'Google indexes the mobile version of a page. Without this tag the desktop ' \
                 'layout is what gets rendered and judged on a phone.', missing)
    end

    # Thin pages are the most common reason a real page never ranks: there is
    # not enough on it for a search engine to decide what it is about.
    def thin_content_check
      thin = docs.reject { |url, _| utility_page?(url) }
                 .select { |_, doc| body_words(doc) < MIN_WORDS_PER_PAGE }.keys
      return pass_check('thin_content', 'Page content', 6, 'Every page carries enough copy to rank') if thin.empty?

      warn_check('thin_content', 'Page content', 6,
                 "#{thin.size} #{pluralize_pages(thin.size)} with very little text",
                 "Under #{MIN_WORDS_PER_PAGE} words there is rarely enough for a search engine to " \
                 'decide what a page is about, so it tends not to rank for anything.', thin)
    end

    # A contact page's job is an address, a phone number, hours and a form. A
    # privacy policy's job is to be accurate. Neither is trying to rank for a
    # search term, and a word count is the wrong instrument for both: a complete
    # contact page routinely lands near a hundred words and is not deficient.
    #
    # This is the same class of defect as flagging a deferred module script for
    # blocking render. A report that flags something every competent site does
    # reads as a form letter, and the one finding a prospect can personally check
    # is the one that decides whether they believe the rest of it.
    UTILITY_PATHS = /
      contact | privacy | terms | legal | disclaimer | accessibility |
      thank[-_]?you | directions | hours | careers | returns | warranty
    /xi

    def utility_page?(url)
      path = URI.parse(url.to_s).path.to_s
      path.match?(UTILITY_PATHS)
    rescue URI::InvalidURIError
      false
    end

    # A proxy for speed from the HTML alone. Not Core Web Vitals, but a blocking
    # script in the head delays first paint on every page on every visit.
    def render_blocking_check
      offenders = docs.select do |_, doc|
        doc.css('head script[src]').any? do |n|
          # type="module" is deferred by spec, so it does not block. Missing
          # that flagged every modern site, including our own dealers', which
          # is the kind of false finding that discredits the whole report.
          next false if n['type'].to_s.casecmp?('module')

          n['async'].nil? && n['defer'].nil?
        end
      end.keys
      return pass_check('render_blocking', 'Render blocking scripts', 4, 'Nothing blocks first paint') if offenders.empty?

      warn_check('render_blocking', 'Render blocking scripts', 4,
                 "#{offenders.size} #{pluralize_pages(offenders.size)} load a script before the page can paint",
                 'A script in the head without async or defer holds up the first paint on every ' \
                 'visit, which is felt most on a phone.', offenders)
    end

    def page_weight_check
      heavy = @pages_html.select { |_, html| html.to_s.bytesize > HEAVY_PAGE_BYTES }.keys
      return pass_check('page_weight', 'Page weight', 4, 'Pages are a reasonable size') if heavy.empty?

      warn_check('page_weight', 'Page weight', 4,
                 "#{heavy.size} #{pluralize_pages(heavy.size)} over #{HEAVY_PAGE_BYTES / 1000}KB of HTML",
                 'Heavy pages are slow on a phone and on a rural connection, which is where a lot ' \
                 'of manufactured home buyers are.', heavy)
    end

    # An insecure asset on a secure page makes a browser show a warning, which
    # costs trust at exactly the wrong moment.
    def mixed_content_check
      offenders = docs.select do |url, doc|
        next false unless url.to_s.start_with?('https://')

        doc.css('img[src], script[src], link[href]').any? { |n| (n['src'] || n['href']).to_s.start_with?('http://') }
      end.keys
      return pass_check('mixed_content', 'Secure assets', 5, 'Everything loads over https') if offenders.empty?

      fail_check('mixed_content', 'Secure assets', 5,
                 "#{offenders.size} #{pluralize_pages(offenders.size)} load something over insecure http",
                 'A browser flags an insecure asset on a secure page, and a visitor deciding ' \
                 'whether to hand over their details sees that warning.', offenders)
    end

    def language_check
      missing = docs.reject { |_, doc| doc.at_css('html')&.[]('lang').present? }.keys
      return pass_check('language', 'Page language', 2, 'Pages declare their language') if missing.empty?

      warn_check('language', 'Page language', 2,
                 "#{missing.size} #{pluralize_pages(missing.size)} do not declare a language",
                 'Search engines use this to decide which audience a page is for, and screen ' \
                 'readers use it to choose a voice.', missing)
    end

    def body_words(doc)
      body = doc.at_css('body')
      return 0 if body.nil?

      body.css('script, style, noscript').each(&:remove)
      body.text.to_s.split(/\s+/).reject(&:blank?).size
    rescue StandardError
      0
    end

    def robots_check
      response = site_file('/robots.txt')
      # Absent evidence is not evidence of absence. A blocked site refuses this
      # file too, and telling a prospect they have no robots.txt when we were
      # simply not allowed to look is the kind of error that discredits the
      # whole report in front of the person who built their site.
      return nil if response.nil? && @from_archive

      if response.nil? || response.body.blank?
        warn_check('robots', 'robots.txt', 3,
                   'No robots.txt',
                   'Without one there is no way to steer crawlers away from pages that should ' \
                   'not be indexed, or to point them at the sitemap.')
      else
        pass_check('robots', 'robots.txt', 3, 'robots.txt is published')
      end
    end

    def sitemap_check
      response = site_file('/sitemap.xml')
      return nil if response.nil? && @from_archive

      count = response && begin
        Nokogiri::XML(response.body).css('url > loc, sitemap > loc').size
      rescue StandardError
        0
      end

      if count.to_i.zero?
        fail_check('sitemap', 'XML sitemap', 6,
                   'No XML sitemap',
                   'A sitemap is how a search engine discovers every listing quickly instead of ' \
                   'finding them by chance. On an inventory site that changes weekly this is the ' \
                   'difference between homes being indexed in days and in months.')
      else
        pass_check('sitemap', 'XML sitemap', 6, "Sitemap lists #{count} URLs")
      end
    end

    # Reported as a finding rather than only a caveat: a site that answers a
    # challenge to everything except Googlebot is invisible to the AI assistants
    # buyers increasingly ask, which matters most for the vendors who advertise
    # AI visibility.
    def crawlability_check
      return nil unless @from_archive

      warn_check('crawlability', 'Crawler access', 7,
                 'The site blocks automated readers',
                 'Requests are challenged before the page is served, so this audit had to read an ' \
                 'archived copy. Search engines are usually allowlisted, but AI assistants such as ' \
                 'ChatGPT and Perplexity are frequently not, which makes the site invisible to them.')
    end

    def site_file(path)
      @site_files ||= {}
      @site_files[path] ||= begin
        uri = URI.parse(@source_url)
        @fetcher.get(URI.join("#{uri.scheme}://#{uri.host}", path).to_s)
      rescue StandardError
        nil
      end
    end

    def meta_content(doc, name)
      doc.at_css("meta[name='#{name}']")&.[]('content').to_s.strip
    end

    def pluralize_pages(count)
      count == 1 ? 'page' : 'pages'
    end

    # Weighted, so a missing sitemap cannot outweigh missing product markup. A
    # warn earns half credit because it is a real but recoverable gap.
    def score(checks)
      total = checks.sum { |c| c.weight.to_i }
      return nil if total.zero?

      earned = checks.sum do |c|
        case c.status
        when 'pass' then c.weight.to_i
        when 'warn' then c.weight.to_i * 0.5
        else 0
        end
      end

      (earned / total * 100).round
    end

    def pass_check(key, label, weight, headline)
      Check.new(key: key, label: label, status: 'pass', headline: headline, weight: weight)
    end

    def warn_check(key, label, weight, headline, detail = nil, urls = [])
      Check.new(key: key, label: label, status: 'warn', headline: headline,
                detail: detail, urls: urls, weight: weight)
    end

    def fail_check(key, label, weight, headline, detail = nil, urls = [])
      Check.new(key: key, label: label, status: 'fail', headline: headline,
                detail: detail, urls: urls, weight: weight)
    end
  end
end
