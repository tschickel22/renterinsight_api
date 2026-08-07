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
        local_business_check,
        breadcrumb_check,
        title_check,
        description_check,
        canonical_check,
        heading_check,
        social_preview_check,
        image_alt_check,
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
        'score' => nil, 'gap_count' => 0, 'checks' => []
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
