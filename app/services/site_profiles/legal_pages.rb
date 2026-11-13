# frozen_string_literal: true

module SiteProfiles
  # A dealer's own Terms and Privacy Policy, read from their current site.
  #
  # A site built from a scan keeps the design's standard legal text unless the
  # dealer already published their own, in which case theirs wins: it is what
  # their lawyer approved and what their customers have already agreed to.
  #
  # The rest of a scan cannot carry this. PageDigest keeps a few hundred words
  # of a page, cut to 500 characters a paragraph, which is right for a model
  # writing an About blurb and wrong for a legal document, which has to be kept
  # whole or not at all. So the two pages are fetched on their own, outside the
  # ten-page budget, and kept as cleaned HTML.
  #
  #   { 'terms'   => { 'url' => '...', 'html' => '<h2>...</h2><p>...</p>' },
  #     'privacy' => { ... } }
  #
  # A kind is left out when the site has no such page or what came back does
  # not read as one. Leaving it out is the safe answer, because projection then
  # keeps the design's own text.
  class LegalPages
    KINDS = {
      'privacy' => {
        link: /privacy/i,
        # A real policy names what it is about. A 404 or a home page served at
        # the policy's URL does not.
        must_mention: /privacy|personal information|information we collect/i
      },
      'terms' => {
        link: /terms|conditions|terms-of-(?:use|service)|legal/i,
        must_mention: /terms|agree|conditions/i
      }
    }.freeze

    # WordPress's starter Privacy Policy, published unedited by a lot of dealer
    # sites (mobilehomesofmississippi.com, 2026-11-13). It covers blog comments
    # and WordPress login cookies and says nothing about lead forms or texting,
    # so on our site it would describe a different website. Ours is better.
    PLATFORM_BOILERPLATE = /Our website address is:|Suggested text:|When visitors leave comments on the site/i

    # Words below which a page is a stub ("Privacy Policy coming soon"), and
    # the design's standard text is the better page.
    MIN_WORDS = 150
    # Above this it is not a policy: the scan landed on something else.
    MAX_CHARS = 80_000

    ALLOWED_TAGS = %w[h2 h3 h4 p ul ol li strong em b i a br].freeze
    ALLOWED_ATTRIBUTES = %w[href].freeze
    MAIN_SELECTOR = 'main, article, [role="main"], .entry-content, .page-content, #content, .content'

    def initialize(digests, base_url:, fetcher:)
      @digests = Array(digests)
      @base_host = host_of(base_url)
      @fetcher = fetcher
    end

    def call
      KINDS.each_with_object({}) do |(kind, rules), out|
        url = link_for(rules[:link], exclude: out.values.map { |v| v['url'] })
        next if url.blank?

        html = read(url, rules)
        out[kind] = { 'url' => url, 'html' => html } if html
      end
    end

    # Exposed for specs: the cleaning step on its own, no fetch.
    def extract(body, rules)
      doc = Nokogiri::HTML(body.to_s)
      doc.search('script, style, noscript, svg, iframe, form, button').each(&:remove)
      doc.search(PageDigest::CHROME_SELECTOR).each(&:remove)

      root = doc.css(MAIN_SELECTOR).max_by { |n| n.text.squish.length } || doc.at('body')
      return nil if root.nil?

      # The page title becomes the hero on our page; keeping it would print it
      # twice. Lower headings move up one level so the text sits under the hero.
      root.css('h1').each(&:remove)
      root.css('h5, h6').each { |h| h.name = 'h4' }

      html = Rails::HTML5::SafeListSanitizer.new.sanitize(
        root.inner_html, tags: ALLOWED_TAGS, attributes: ALLOWED_ATTRIBUTES
      )
      html = strip_empty(html)

      text = Nokogiri::HTML.fragment(html).text.squish
      return nil if text.split.size < MIN_WORDS
      return nil if html.length > MAX_CHARS
      return nil unless rules[:must_mention].match?(text)
      return nil if PLATFORM_BOILERPLATE.match?(text)

      html
    end

    private

    def link_for(pattern, exclude: [])
      candidates = @digests.flat_map { |d| Array(d.links) }.filter_map do |link|
        href = (link[:href] || link['href']).to_s
        label = (link[:label] || link['label']).to_s.squish
        uri = safe_parse(href)
        next if uri.nil? || uri.host.blank? || host_of(href) != @base_host
        next if uri.path.to_s.match?(/\.pdf\z/i)

        path = uri.path.to_s
        next unless pattern.match?(path) || pattern.match?(label)

        uri.fragment = nil
        [uri.to_s, label]
      end

      # "Privacy Policy" in the label beats a path that merely contains the word.
      best = candidates.min_by { |(_url, label)| pattern.match?(label) ? 0 : 1 }
      url = best&.first
      exclude.include?(url) ? nil : url
    end

    def read(url, rules)
      # Never from the Wayback Machine: an archived policy may be one the dealer
      # has since replaced, and publishing the old one is worse than ours.
      response = @fetcher.get(url, allow_archive: false)
      return nil if response.nil? || response.body.blank?

      extract(response.body, rules)
    rescue StandardError => e
      Rails.logger.warn "[SiteProfiles::LegalPages] #{url}: #{e.class}: #{e.message}"
      nil
    end

    def strip_empty(html)
      frag = Nokogiri::HTML.fragment(html)
      frag.css('p, li, h2, h3, h4, strong, em, b, i').each do |node|
        node.remove if node.text.squish.empty? && node.css('br').empty?
      end
      frag.to_html.gsub(/\n{2,}/, "\n").strip
    end

    def safe_parse(href)
      URI.parse(href)
    rescue URI::InvalidURIError
      nil
    end

    def host_of(url)
      URI.parse(url.to_s).host.to_s.downcase.sub(/\Awww\./, '')
    rescue URI::InvalidURIError
      ''
    end
  end
end
