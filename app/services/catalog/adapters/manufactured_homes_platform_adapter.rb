# frozen_string_literal: true

module Catalog
  module Adapters
    # Adapter for the ManufacturedHomes.com platform (WordPress/Elementor, SSR —
    # no headless browser). One adapter unlocks EVERY manufacturer on the
    # platform: onboard a new one by adding a CatalogSource row with that
    # manufacturer's id (e.g. Sunshine = "2459"), not by writing code.
    #
    # Identity: the numeric floorplanId from the detail URL
    #   /floor-plan-detail/{floorplanId}-{dealerId}/...   (e.g. 235410)
    # is the stable source_key. The trailing dealerId is retailer context, NOT
    # identity, and is stashed in `raw` only.
    #
    # TWO PERMALINK BASES, ONE PLATFORM. Sites are free to mount the platform's
    # floor plan pages wherever they like: Sunshine uses /floor-plan-detail/,
    # Timber Creek uses /floorplan/. The markup underneath is identical (the
    # same fp-card-* classes, the same specification_tabs widget, the same
    # CloudFront media host), so both are matched rather than forked into a
    # second adapter.
    #
    # DEALER-SCOPED SOURCES. base_url may be a manufacturer's full floor plan
    # grid OR one retailer's page (/dealer/{dealerId}/{slug}/{city}/). The
    # latter is the ManufacturedHomes.com equivalent of a Clayton home center:
    # the platform itself decides which homes that retailer offers, so a dealer
    # subscribed to their own page gets their inventory and nobody else's with
    # no radius math on our side. See #dealer_scoped? for what changes.
    #
    # CALIBRATION NOTE: selectors below are anchored on og:/meta tags and
    # labeled text (resilient) with grid-derived fallbacks, but the exact label
    # strings and the detail-page feature/section markup must be verified
    # against live Sunshine HTML on first run. Each field has its own extractor,
    # so a miss shows up as one dropped extraction rate — not a failed run.
    class ManufacturedHomesPlatformAdapter < BaseAdapter
      GRID_PATH        = '/manufactured-home-floor-plans/'
      DETAIL_PATH_RE   = %r{/(?:floor-plan-detail|floorplan)/(\d+)-(\d+)(?:/|\z)}i
      DETAIL_SELECTOR  = 'a[href*="/floor-plan-detail/"], a[href*="/floorplan/"]'
      CARD_SELECTOR    = '.fp-card-container, .floorplan-default'
      DEALER_PATH_RE   = %r{/dealer/(\d+)(?:/|\z)}i
      CLOUDFRONT_HOST  = 'd132mt2yijm03y.cloudfront.net'
      MATTERPORT_RE    = %r{https?://(?:my\.)?matterport\.com/show/\?[^\s"'<>)]*m=[A-Za-z0-9]+[^\s"'<>)]*}i
      MAX_PAGES        = 25

      # Sequential, single-threaded crawl, so 2s between requests is plenty polite
      # for a commercial site — 5s made a ~97-home run take ~10 min in-Puma.
      # Override per source via config { "crawl_delay": N }.
      def crawl_delay
        Integer(source.config['crawl_delay'] || 2)
      end

      # Walk the paginated grid (or sitemap, if cleaner) collecting floorplanIds.
      # The full slugged detail URL is cached per key so fetch() can hit the
      # canonical page directly (the URL carries dealer/city/series/name slugs we
      # can't reconstruct from the id alone). Grid cards are cached too, so
      # parse() can fall back to grid-derived fields.
      def discover(limit: nil)
        @cards       ||= {}
        @detail_urls ||= {}
        # A sitemap is site-wide by definition, so for a dealer-scoped source it
        # would quietly return every retailer's homes — exactly the leak this
        # source shape exists to prevent. Only the grid is dealer-scoped.
        keys = dealer_scoped? ? [] : discover_via_sitemap
        keys = discover_via_grid(limit: limit) if keys.blank?
        limit ? keys.first(limit) : keys
      end

      # This source is one retailer's page rather than a manufacturer-wide grid.
      # Set explicitly via config { "dealer_id": "1982" }, or inferred from a
      # /dealer/{id}/ base_url.
      def dealer_scoped?
        dealer_id.present?
      end

      def dealer_id
        @dealer_id ||= source.config['dealer_id'].presence ||
                       base_url[DEALER_PATH_RE, 1]
      end

      def fetch(key)
        url  = (@detail_urls || {})[key.to_s] || detail_url(key)
        html = http_get(url)
        { key: key.to_s, url: url, html: html, card: (@cards || {})[key.to_s] || {} }
      end

      def parse(raw)
        doc  = raw[:html].present? ? Nokogiri::HTML(raw[:html]) : nil
        # Drop <script>/<style> so inline CSS (e.g. "3000px 1500px") can't poison
        # the number/dimension regexes that scan doc.text.
        doc&.css('script, style, noscript')&.remove
        card = raw[:card] || {}
        html = raw[:html].to_s

        NormalizedHome.new(
          source_key:       raw[:key],
          source_url:       raw[:url],
          model_name:       extract_name(doc, card),
          model_id:         extract_model_id(doc, card),
          series:           extract_series(doc, card),
          property_type:    extract_property_type(doc, card),
          bedrooms:         to_int(extract_beds(doc, card)),
          bathrooms:        to_decimal(extract_baths(doc, card)),
          dimensions:       extract_dimensions(doc, card),
          square_feet:      to_int(extract_sqft(doc, card)),
          description:      extract_description(doc, card),
          features:         extract_features(doc),
          images:           extract_images(doc, html, card, raw[:key]),
          virtual_tour_url: scan_regex(html, MATTERPORT_RE),
          video_url:        extract_video(html),
          price_quote_url:  extract_quote_url(doc, raw[:url]),
          raw: {
            'manufacturer_id' => source.manufacturer_id,
            'dealer_id'       => raw[:key].to_s.split('-').last
          }
        )
      end

      # Explains a zero-discovery result: did the grid fetch, what status, how
      # many detail links / cloudfront images did the server actually see, and
      # does it look like a block page or a location-empty grid?
      def diagnostics
        out = { adapter: 'manufacturedhomes_platform' }
        probe = http_probe(grid_url(1))
        out[:grid_url]        = grid_url(1)
        out[:grid_status]     = probe[:status]
        out[:grid_redirect]   = probe[:location]
        out[:grid_bytes]      = probe[:bytes]
        out[:error]           = probe[:error] if probe[:error]

        if probe[:body].present?
          doc = Nokogiri::HTML(probe[:body])
          out[:detail_links]   = doc.css(DETAIL_SELECTOR).size
          out[:dealer_id]      = dealer_id if dealer_scoped?
          out[:cloudfront_imgs] = probe[:body].scan(CLOUDFRONT_HOST).size
          out[:page_title]     = doc.at_css('title')&.text.to_s.strip[0, 80]
          out[:looks_blocked]  = looks_blocked?(probe[:body])
          out[:near_text]      = probe[:body][/near\s+[A-Z][A-Za-z .,]{0,30}/i]
        end

        sm = http_probe("#{site_root}/sitemap.xml", accept: 'application/xml')
        out[:sitemap_status] = sm[:status]
        out
      end

      private

      # --- Discovery -------------------------------------------------------

      # Best-effort: most ManufacturedHomes.com detail pages are platform-
      # generated and absent from the WordPress sitemap, so this usually returns
      # [] for these sites and discovery falls through to the grid. Kept because
      # some sites DO surface /floor-plan-detail/ URLs here (one cheap request).
      def discover_via_sitemap
        %w[/sitemap.xml /sitemap_index.xml /wp-sitemap.xml].each do |path|
          body = http_get("#{site_root}#{path}", accept: 'application/xml,text/xml')
          next if body.blank?

          locs = Nokogiri::XML(body).remove_namespaces!.css('loc').map(&:text)
          keys = locs.filter_map do |loc|
            key = loc[DETAIL_PATH_RE, 1]
            next if key.blank?

            @detail_urls[key] = loc
            key
          end.uniq
          return keys if keys.any?
        end
        []
      rescue StandardError => e
        Rails.logger.warn "[#{self.class.name}] sitemap discovery failed: #{e.message}"
        []
      end

      def discover_via_grid(limit: nil)
        keys = []
        (1..MAX_PAGES).each do |page|
          doc = doc_for(grid_url(page))
          break if doc.nil?

          found    = harvest_grid_cards(doc)
          new_keys = found - keys
          break if new_keys.empty? # empty page, or a site that clamps ?pg to the last page

          keys.concat(new_keys)
          break if limit && keys.size >= limit

          sleep(crawl_delay) unless Rails.env.test?
        end
        keys
      end

      # Pulls floorplanIds + full detail URLs off a grid page and caches each
      # card's quick-fields (name/series/beds/baths/sqft/dimensions/image).
      def harvest_grid_cards(doc)
        keys = []
        doc.css(DETAIL_SELECTOR).each do |link|
          href  = link['href'].to_s
          match = href.match(DETAIL_PATH_RE)
          next if match.nil?

          key = match[1]
          next if key.blank? || keys.include?(key)
          # Belt and braces on top of the dealer-scoped grid: the detail URL
          # carries the dealer id, so anything offered by a different retailer
          # is dropped even if the page ever starts cross-linking them.
          next if dealer_scoped? && match[2] != dealer_id.to_s

          keys << key
          @detail_urls[key] ||= absolute_url(href, URI.parse(site_root))
          card_root = link.ancestors(CARD_SELECTOR).first ||
                      link.ancestors('article, li, div').first || link
          @cards[key] ||= parse_grid_card(card_root)
        end
        keys
      end

      # The grid card (.fp-card-container / .floorplan-default) carries the specs
      # as an ICON row that renders to a number-only run in text order beds /
      # baths / sqft / dims, e.g. "… Lifeway Homes of Tulsa 4 2.00 2400 ft²
      # 32'0\" x 84'0\" The Show…". This is the RELIABLE spec source — it's in
      # the discovery HTML (which works everywhere), whereas the detail-page spec
      # summary is location-aware and gets stripped for some server IPs.
      def parse_grid_card(node)
        text  = node.text.gsub(/\s+/, ' ').strip
        specs = text.match(/(\d+(?:\.\d+)?)\s+(\d+(?:\.\d+)?)\s+([\d,]{3,6})\s*ft/i)
        title = node.at_css('.home-name, h4, h3')&.text.to_s.gsub(/\s+/, ' ').strip
        {
          'title'      => title.presence,
          'series'     => series_from_heading(title),
          'beds'       => specs && specs[1],
          'baths'      => specs && specs[2],
          'sqft'       => specs && specs[3],
          'dimensions' => text[DIMENSIONS_RE],
          'image'      => card_image(node)
        }.compact
      end

      # The card thumbnail is a CSS background, not an <img>: Sunshine inlines it
      # as style="background-image: url(…)", Timber Creek defers it to a
      # lazyload data-bg. Check both, and keep the <img> sweep for any site that
      # renders a real element.
      def card_image(node)
        node.css('[data-bg], [style*="background-image"], img').each do |el|
          candidate = first_attr(el, %w[data-bg data-src data-lazy-src src]) ||
                      el['style'].to_s[/url\(\s*['"]?([^'")]+)/, 1]
          return candidate if candidate.to_s.include?(CLOUDFRONT_HOST)
        end
        nil
      end

      # --- Field extractors (anchor on meta/labels, fall back to grid card) --

      # "PRI3268-2004" (Sunshine) and "CS-1604" (Timber Creek) — the hyphen
      # between the letters and the first number group is optional.
      MODEL_ID_RE = /\b([A-Z]{2,4}-?\d{3,4}(?:-\d+)?)\b/

      # Heading shape is "<Series><sep><Name> <ModelId>". The separator is "/" on
      # the grid card and on Sunshine's H1, "|" on Timber Creek's H1, and the
      # series itself may be more than one word ("Creekside Series").
      SERIES_SPLIT_RE = %r{\A([A-Za-z][A-Za-z0-9&'’. -]{0,40}?)\s*[/|]\s*(?=\S)}
      # Sunshine names its series inline with no separator at all.
      SUNSHINE_SERIES_RE = /\A(Prime|ARC|Velocity|Innovation)\b/i

      # The H1 ("Prime / The Show Stopper PRI3284-2058") is the clean, reliable
      # source for name/series/model_id. og:title on this platform is a generic
      # "Floor Plan Detail", so we deliberately ignore it; the <title>
      # ("<Series> <Name> <ModelId> - Sunshine Homes") is the fallback.
      def heading(doc)
        return '' if doc.nil?

        h1 = doc.at_css('h1')&.text&.gsub(/\s+/, ' ')&.strip
        return h1 if h1.present?

        clean_title(doc.at_css('title')&.text).to_s
      end

      def extract_name(doc, card)
        h = heading(doc).presence || card['title'].to_s
        return card['name'] if h.blank?

        name_from_heading(h) || card['name']
      end

      # "Creekside Series | The Cahaba CS-1604" -> "The Cahaba"
      # "Prime / The Show Stopper PRI3284-2058" -> "The Show Stopper"
      def name_from_heading(heading)
        heading.sub(SERIES_SPLIT_RE, '')
               .sub(/\A(?:Prime|ARC|Velocity|Innovation)\s+/i, '')
               .sub(/\s*#{MODEL_ID_RE}\s*\z/, '')
               .strip.presence
      end

      def series_from_heading(heading)
        return nil if heading.blank?

        (heading[SERIES_SPLIT_RE, 1] || heading[SUNSHINE_SERIES_RE, 1])&.strip.presence
      end

      def extract_model_id(doc, card)
        heading(doc)[MODEL_ID_RE, 1] || card['title'].to_s[MODEL_ID_RE, 1] || card['model_id']
      end

      def extract_series(doc, card)
        series_from_heading(heading(doc)) || card['series'] ||
          extract_spec(doc, card, %w[series collection])
      end

      PROPERTY_TYPE_RE = /\A(manufactured|modular)\z/i
      # Chrome that mentions both types on every page regardless of the home.
      CHROME_SELECTOR  = 'nav, header, footer, .elementor-nav-menu, .menu, [class*="nav-menu"]'

      # The platform tags each home explicitly — a .tag/.label pill reading
      # "Manufactured" or "Modular" — and that is the only trustworthy source.
      #
      # This used to scan the whole page text for either word, which matched the
      # site's own nav ("Manufactured Homes", "Modular Homes") on every single
      # page. Every home came back as BOTH types, on Timber Creek and Sunshine
      # alike. The fallback keeps the text scan for a site with no pills, but
      # strips the nav first so it cannot make the same mistake.
      def extract_property_type(doc, _card)
        return [] if doc.nil?

        tagged = doc.css('.tags li, .tags .tag, .fp-card-tags li, .label, .tag')
                    .map { |n| n.text.to_s.strip }
                    .select { |t| t.match?(PROPERTY_TYPE_RE) }
                    .map(&:capitalize).uniq
        return tagged if tagged.any?

        body = doc.dup
        body.css(CHROME_SELECTOR).remove
        body.text.scan(/\b(manufactured|modular)\b/i).flatten.map(&:capitalize).uniq
      end

      # Specs render as value-then-label on this platform ("4 Beds", "2.00 Baths",
      # "2400 Sq. Ft.") — number precedes the label — so anchor on that shape
      # first, then fall back to the grid card, then the generic label scan.
      # Grid card FIRST (reliable everywhere), detail-page text as fallback.
      def extract_beds(doc, card)
        card['beds'] || text_number(doc, /([\d.]+)\s*beds?\b/i) ||
          extract_spec(doc, card, %w[bedroom bedrooms beds bed])
      end

      def extract_baths(doc, card)
        card['baths'] || text_number(doc, /([\d.]+)\s*baths?\b/i) ||
          extract_spec(doc, card, %w[bathroom bathrooms baths bath])
      end

      def extract_sqft(doc, card)
        card['sqft'] || text_number(doc, /([\d,]{3,})\s*sq\.?\s*ft/i) ||
          extract_spec(doc, card, ['square feet', 'sq ft', 'sqft', 'square footage'])
      end

      # Dimensions render with curly typography: 32’0″ x 84’0″ — the foot mark is
      # ’ (U+2019), the inch mark ″ (U+2033), NOT plain ' and ".
      DIMENSIONS_RE = /\d+[’'′]\s*\d*[″"]?\s*[xX×]\s*\d+[’'′]\s*\d*[″"]?/

      def extract_dimensions(doc, card)
        card['dimensions'] || (doc && doc.text[DIMENSIONS_RE]).presence ||
          extract_spec(doc, card, %w[dimensions size])
      end

      def text_number(doc, regex)
        return nil if doc.nil?

        doc.text[regex, 1]
      end

      # Reads a labeled spec value from the detail page. ManufacturedHomes.com
      # renders specs as label→value pairs (dt/dd, spec rows, counter boxes).
      # We match any label containing one of `labels`, then take its sibling /
      # following value node; regex fallback over the page text last.
      def extract_spec(doc, card, labels)
        # Grid-card fast path
        labels.each do |l|
          key = { 'bed' => 'beds', 'bath' => 'baths', 'sq ft' => 'sqft',
                  'square feet' => 'sqft', 'dimensions' => 'dimensions',
                  'series' => 'series' }[l.downcase]
          return card[key] if key && card[key].present?
        end
        return nil if doc.nil?

        node = doc.css('dt, th, .spec-label, [class*="label"], strong, b').find do |label_node|
          labels.any? { |l| label_node.text.to_s.strip.downcase.include?(l.downcase) }
        end
        if node
          value = node.next_element&.text&.strip
          value = node.parent&.at_css('dd, td, .spec-value, [class*="value"]')&.text&.strip if value.blank?
          return value if value.present?
        end

        # Last-ditch regex over visible text, e.g. "Bedrooms: 3"
        labels.each do |l|
          m = doc.text.match(/#{Regexp.escape(l)}\s*[:\-]?\s*([0-9][0-9'".,xX×\s]*)/i)
          return m[1].strip if m
        end
        nil
      end

      # Some sites never fill the Elementor template's own og:description, so the
      # tag ships with the UNRENDERED placeholder copy ("Spec 1 Spec 2 Key 1:
      # value 1 … Read More... from Floorplan"). That is worse than no
      # description at all, because it looks populated. Prefer the on-page
      # "Description" section, and reject the placeholder when falling back.
      BOILERPLATE_DESC_RE = /key 1:\s*value 1|spec 1\s+spec 2|read more\.{2,}\s*from floorplan/i

      def extract_description(doc, card)
        section_description(doc).presence ||
          meta_description(doc).presence ||
          doc&.at_css('.home-description, [class*="description"] p, article p')&.text&.strip.presence ||
          card['description']
      end

      # The description is a text-editor widget sitting after a "Description"
      # heading, with no class of its own to anchor on.
      def section_description(doc)
        return nil if doc.nil?

        heading = doc.css('h1, h2, h3, h4').find { |h| h.text.to_s.strip.casecmp?('description') }
        return nil unless heading

        block = heading.ancestors('.elementor-widget, section, div').first
        text  = block&.next_element&.text.to_s.gsub(/\s+/, ' ').strip
        text = heading.xpath('following::*[self::p or self::div][1]')
                      .first&.text.to_s.gsub(/\s+/, ' ').strip if text.blank?
        text.presence
      end

      def meta_description(doc)
        meta = doc&.at_css('meta[property="og:description"], meta[name="description"]')&.[]('content')
        return nil if meta.blank? || meta.match?(BOILERPLATE_DESC_RE)

        meta
      end

      # Detail-page "Specifications" tabs (Construction / Exterior / Interior /
      # Baths / Kitchen). Each is a Bootstrap nav-tab whose panel (.tab-pane) holds
      # the spec lines as <span>s separated by <br>. Falls back to a generic
      # heading→list scan for sites that don't use the tab layout.
      def extract_features(doc)
        return {} if doc.nil?

        tabs = tab_features(doc)
        return tabs if tabs.any?

        features = {}
        doc.css('h2, h3, h4').each do |heading|
          title = heading.text.to_s.strip
          next if title.blank?

          list = heading.xpath('following-sibling::*[self::ul or self::ol][1]').first
          next unless list

          items = list.css('li').map { |li| li.text.strip }.reject(&:blank?).uniq
          features[title] = items if items.any?
        end
        features
      end

      def tab_features(doc)
        labels = doc.css('.nav-tabs li, li.nav-item').map { |n| n.text.strip }.reject(&:blank?)
        panes  = doc.css('.tab-content .tab-pane')
        out = {}
        panes.each_with_index do |pane, i|
          title = labels[i].presence || pane['id'].to_s.sub(/\Atab[_-]?/i, '').tr('_-', ' ').strip.titleize
          next if title.blank?

          # Each spec line is "<span>Label:</span> value" separated by <br>, so
          # split on <br> to keep label AND value together on one line.
          html  = pane.inner_html.gsub(%r{<br\s*/?>}i, "\n")
          items = Nokogiri::HTML.fragment(html).text.split("\n")
                          .map { |l| l.gsub(/\s+/, ' ').strip }.reject(&:blank?).uniq
          out[title] = items if items.any?
        end
        out
      end

      # Walkthrough video (YouTube/Vimeo) — NOT social channel links. Matterport
      # is captured separately as virtual_tour_url.
      def extract_video(html)
        return nil if html.blank?

        (html[%r{https?://(?:www\.)?youtube\.com/(?:watch\?v=|embed/)[A-Za-z0-9_-]{6,}}i] ||
         html[%r{https?://youtu\.be/[A-Za-z0-9_-]{6,}}i] ||
         html[%r{https?://(?:www\.|player\.)?vimeo\.com/(?:video/)?\d{5,}}i])
      end

      # Full gallery from the detail page plus the grid floorplan image. Prefer
      # CloudFront-hosted assets (the manufacturer's own media); tag floorplans.
      def extract_images(doc, html, card, key = nil)
        urls = []
        if doc
          doc.css('img').each do |img|
            src = first_attr(img, %w[data-src data-lazy-src data-orig-src src])
            urls << { url: src, alt: img['alt'].to_s } if src.to_s.include?(CLOUDFRONT_HOST)
          end
        end
        # Sweep raw HTML for CloudFront URLs not present as <img> attributes.
        html.to_s.scan(%r{https?://#{Regexp.escape(CLOUDFRONT_HOST)}/[^\s"'<>)]+}i).each do |u|
          urls << { url: u, alt: '' }
        end
        urls << { url: card['image'], alt: 'floorplan' } if card['image'].present?

        drop_thumbnails(dedupe_images(scope_to_home(urls, key)))
      end

      # Detail pages carry a "similar homes" rail whose imagery belongs to OTHER
      # floor plans (and other manufacturers entirely). CloudFront paths are
      # segmented .../floorplan/{floorplanId}/..., so keep only this home's own
      # media. Applied only when the page actually yields matches, so a site that
      # ever files media differently degrades to the old behaviour rather than
      # returning a home with no pictures.
      def scope_to_home(urls, key)
        return urls if key.blank?

        segment = "/floorplan/#{key}/"
        scoped  = urls.select { |i| i[:url].to_s.include?(segment) }
        scoped.any? ? scoped : urls
      end

      # The gallery publishes each shot twice, as "Cahaba-1.jpg" and
      # "Cahaba-1_thumb_xxl.jpg". Both render, but keeping the thumbnail doubles
      # the gallery, doubles what the image archiver downloads and stores, and
      # puts a half-size copy in the listing.
      THUMB_SUFFIX_RE = /_(?:thumb[a-z_]*|card[a-z_]*|small|medium)(?=\.[a-z]{3,4}\z)/i

      def drop_thumbnails(images)
        full = images.reject { |i| i['source_url'].to_s.match?(THUMB_SUFFIX_RE) }
        return images if full.empty?

        originals = full.map { |i| i['source_url'] }.to_set
        images.reject do |img|
          url = img['source_url'].to_s
          url.match?(THUMB_SUFFIX_RE) && originals.include?(url.sub(THUMB_SUFFIX_RE, ''))
        end
      end

      def extract_quote_url(doc, page_url)
        return nil if doc.nil?

        link = doc.css('a').find do |a|
          a.text.to_s.match?(/price|quote|request info/i) ||
            a['href'].to_s.match?(/quote|price-request|request-info/i)
        end
        href = link&.[]('href')
        href.present? ? absolute_url(href, URI.parse(page_url)) : nil
      rescue StandardError
        nil
      end

      # --- Helpers ---------------------------------------------------------

      def dedupe_images(raw_images)
        seen = {}
        raw_images.each do |img|
          url = img[:url].to_s.strip
          next if url.blank?

          seen[url] ||= {
            'source_url'   => url,
            'local_url'    => nil,
            'alt'          => img[:alt].to_s,
            'is_floorplan' => floorplan?(url, img[:alt])
          }
        end
        seen.values
      end

      # Tag floorplans by the image FILENAME / alt only — never the URL path. The
      # CloudFront path always contains ".../floorplan/{id}/...", so matching the
      # full URL would mistag the entire gallery as floor plans.
      def floorplan?(url, alt)
        basename = File.basename(url.to_s.split('?').first.to_s)
        "#{basename} #{alt}".downcase.match?(/floor[\s_-]?plan/)
      end

      def clean_title(title)
        return nil if title.blank?

        title.to_s.split(%r{\s+[|•–]\s+|\s+-\s+}).first&.strip.presence
      end

      # The source base_url IS the floor-plan listing page (it already includes
      # the listing path), so page 1 is the listing itself and later pages add
      # ?pg=N — do NOT append a second listing path segment.
      def grid_url(page)
        page.to_i <= 1 ? listing_url : "#{listing_url}?pg=#{page}"
      end

      # Fallback only — discovery normally caches the full slugged URL from the
      # grid. The id-and-dealer form 301s to the canonical, which http_get follows.
      # The permalink base differs per site, so prefer one observed during
      # discovery; config { "detail_path": "/floorplan/" } pins it when a source
      # is fetched without a preceding discover.
      def detail_url(key)
        dealer = dealer_id || source.manufacturer_id
        suffix = dealer.present? ? "#{key}-#{dealer}" : key.to_s
        "#{site_root}#{detail_path}#{suffix}/"
      end

      def detail_path
        path = source.config['detail_path'].presence ||
               observed_detail_path ||
               '/floor-plan-detail/'
        "/#{path.to_s.strip.delete_prefix('/').delete_suffix('/')}/"
      end

      def observed_detail_path
        url = (@detail_urls || {}).values.first
        url.to_s[%r{(/(?:floor-plan-detail|floorplan)/)}i, 1]
      end

      # The listing page URL (base_url, normalized to a single trailing slash).
      def listing_url
        "#{source.base_url.to_s.strip.sub(%r{/+\z}, '')}/"
      end

      # Scheme + host of the source, for absolutizing relative detail hrefs and
      # locating sitemaps.
      def site_root
        uri = URI.parse(source.base_url.to_s)
        "#{uri.scheme}://#{uri.host}"
      rescue StandardError
        source.base_url.to_s
      end

      def to_int(value)
        return nil if value.blank?

        digits = value.to_s.gsub(/[^\d]/, '')
        digits.presence&.to_i
      end

      def to_decimal(value)
        return nil if value.blank?

        m = value.to_s.match(/\d+(\.\d+)?/)
        m && m[0]
      end
    end
  end
end
