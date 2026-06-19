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
    # CALIBRATION NOTE: selectors below are anchored on og:/meta tags and
    # labeled text (resilient) with grid-derived fallbacks, but the exact label
    # strings and the detail-page feature/section markup must be verified
    # against live Sunshine HTML on first run. Each field has its own extractor,
    # so a miss shows up as one dropped extraction rate — not a failed run.
    class ManufacturedHomesPlatformAdapter < BaseAdapter
      GRID_PATH        = '/manufactured-home-floor-plans/'
      DETAIL_PATH_RE   = %r{/floor-plan-detail/(\d+)-(\d+)/}i
      CLOUDFRONT_HOST  = 'd132mt2yijm03y.cloudfront.net'
      MATTERPORT_RE    = %r{https?://(?:my\.)?matterport\.com/show/\?[^\s"'<>)]*m=[A-Za-z0-9]+[^\s"'<>)]*}i
      MAX_PAGES        = 25

      def crawl_delay
        Integer(source.config['crawl_delay'] || 5)
      end

      # Walk the paginated grid (or sitemap, if cleaner) collecting floorplanIds.
      # The full slugged detail URL is cached per key so fetch() can hit the
      # canonical page directly (the URL carries dealer/city/series/name slugs we
      # can't reconstruct from the id alone). Grid cards are cached too, so
      # parse() can fall back to grid-derived fields.
      def discover(limit: nil)
        @cards       ||= {}
        @detail_urls ||= {}
        keys = discover_via_sitemap
        keys = discover_via_grid(limit: limit) if keys.blank?
        limit ? keys.first(limit) : keys
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
          images:           extract_images(doc, html, card),
          virtual_tour_url: scan_regex(html, MATTERPORT_RE),
          price_quote_url:  extract_quote_url(doc, raw[:url]),
          raw: {
            'manufacturer_id' => source.manufacturer_id,
            'dealer_id'       => raw[:key].to_s.split('-').last
          }
        )
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
        doc.css('a[href*="/floor-plan-detail/"]').each do |link|
          href = link['href'].to_s
          key  = href[DETAIL_PATH_RE, 1]
          next if key.blank? || keys.include?(key)

          keys << key
          @detail_urls[key] ||= absolute_url(href, URI.parse(site_root))
          card_root = link.ancestors('article, li, div').first || link
          @cards[key] ||= parse_grid_card(card_root)
        end
        keys
      end

      def parse_grid_card(node)
        text = node.text.to_s
        {
          'name'        => node.at_css('h2, h3, .home-title, [class*="title"]')&.text&.strip,
          'series'      => text[/\b(Prime|ARC|Velocity|Innovation)\b/i, 1],
          'beds'        => text[/(\d+(?:\.\d+)?)\s*(?:bed|bd)/i, 1],
          'baths'       => text[/(\d+(?:\.\d+)?)\s*(?:bath|ba)/i, 1],
          'sqft'        => text[/([\d,]{3,})\s*(?:sq\.?\s*ft|sqft)/i, 1],
          'dimensions'  => text[/\d+[’'′]\s*\d*[″"]?\s*[xX×]\s*\d+[’'′]\s*\d*[″"]?/],
          'image'       => node.css('img').map { |i| first_attr(i, %w[data-src data-lazy-src src]) }
                               .compact.find { |u| u.include?(CLOUDFRONT_HOST) }
        }.compact
      end

      # --- Field extractors (anchor on meta/labels, fall back to grid card) --

      MODEL_ID_RE = /\b([A-Z]{2,4}\d{3,4}(?:-\d+)?)\b/

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
        h = heading(doc)
        return card['name'] if h.blank?

        h.sub(%r{\A[A-Za-z]+\s*/\s*}, '')                     # "Prime / X" -> "X"
         .sub(/\A(?:Prime|ARC|Velocity|Innovation)\s+/i, '')  # "Prime X"   -> "X"
         .sub(/\s*#{MODEL_ID_RE}\s*\z/, '')                   # drop trailing model id
         .strip.presence || card['name']
      end

      def extract_model_id(doc, card)
        heading(doc)[MODEL_ID_RE, 1] || card['model_id']
      end

      def extract_series(doc, card)
        h = heading(doc)
        # "Prime / The Show Stopper" (slug) or "Prime The Show Stopper …" (title).
        series = h[%r{\A([A-Za-z]+)\s*/}, 1] ||
                 h[/\A(Prime|ARC|Velocity|Innovation)\b/i, 1]
        series.presence || card['series'] || extract_spec(doc, card, %w[series collection])
      end

      def extract_property_type(doc, _card)
        return [] if doc.nil?

        doc.text.scan(/\b(manufactured|modular)\b/i).flatten.map(&:capitalize).uniq
      end

      # Specs render as value-then-label on this platform ("4 Beds", "2.00 Baths",
      # "2400 Sq. Ft.") — number precedes the label — so anchor on that shape
      # first, then fall back to the grid card, then the generic label scan.
      def extract_beds(doc, card)
        text_number(doc, /([\d.]+)\s*beds?\b/i) || card['beds'] ||
          extract_spec(doc, card, %w[bedroom bedrooms beds bed])
      end

      def extract_baths(doc, card)
        text_number(doc, /([\d.]+)\s*baths?\b/i) || card['baths'] ||
          extract_spec(doc, card, %w[bathroom bathrooms baths bath])
      end

      def extract_sqft(doc, card)
        text_number(doc, /([\d,]{3,})\s*sq\.?\s*ft/i) || card['sqft'] ||
          extract_spec(doc, card, ['square feet', 'sq ft', 'sqft', 'square footage'])
      end

      # Dimensions render with curly typography: 32’0″ x 84’0″ — the foot mark is
      # ’ (U+2019), the inch mark ″ (U+2033), NOT plain ' and ".
      DIMENSIONS_RE = /\d+[’'′]\s*\d*[″"]?\s*[xX×]\s*\d+[’'′]\s*\d*[″"]?/

      def extract_dimensions(doc, card)
        dims = doc && doc.text[DIMENSIONS_RE]
        dims.presence || card['dimensions'] || extract_spec(doc, card, %w[dimensions size])
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

      def extract_description(doc, card)
        meta = doc&.at_css('meta[property="og:description"], meta[name="description"]')&.[]('content')
        meta.presence ||
          doc&.at_css('.home-description, [class*="description"] p, article p')&.text&.strip ||
          card['description']
      end

      # Detail-page feature lists, grouped by their section heading.
      def extract_features(doc)
        return {} if doc.nil?

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

      # Full gallery from the detail page plus the grid floorplan image. Prefer
      # CloudFront-hosted assets (the manufacturer's own media); tag floorplans.
      def extract_images(doc, html, card)
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

        dedupe_images(urls)
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
      def detail_url(key)
        dealer = source.config['dealer_id'] || source.manufacturer_id
        suffix = dealer.present? ? "#{key}-#{dealer}" : key.to_s
        "#{site_root}/floor-plan-detail/#{suffix}/"
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
