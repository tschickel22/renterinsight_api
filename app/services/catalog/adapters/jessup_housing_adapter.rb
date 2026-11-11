# frozen_string_literal: true

module Catalog
  module Adapters
    # Adapter for Jessup Housing (jessuphousing.com): WordPress, Astra theme,
    # Beaver Builder pages. Homes are ordinary WordPress PAGES nested under a
    # series page (/the-elite-series/the-nixon/), not a custom post type, so
    # discovery reads the Yoast page sitemap and keeps two-segment paths under
    # a "-series" parent. No headless browser.
    #
    # Identity: the page slug ("the-nixon", "bahama-28x76") is the source_key,
    # so discovery and parse agree without fetching. The model number
    # (SPS16682A, ELT32685B, FAC28765A) is printed on every page and goes in
    # model_id.
    #
    # Every home page is the same Beaver Builder layout, in this order:
    #   h2 name ("THE NIXON", "BAHAMA 28X76")
    #   h2 model number
    #   p  "2 Bed | 2 Bath | 1,065 Square Feet"
    #   FLOORPLAN photo module + "Download Floorplan" PDF button
    #   GALLERY   mosaic gallery module(s), full size image on the <a href>
    #   FEATURES  h4 section headings, each followed by a rich-text list
    #             (<ul><li> on most pages, "•" lines split by <br> on others)
    #   POPULAR OPTIONS (Promotional series) a list with no prices
    #
    # CALIBRATED against all 18 homes on 2026-11-11:
    #   name, model number, beds, baths, sq ft, floor plan, features   18/18
    #   gallery photos                                                  17/18 (Bahama has none yet)
    #   Matterport tour                                                 17/18 (Bahama again)
    #   prose description                                       not published
    #
    # Dimensions are on the page only for Promotional homes (in the name). The
    # model number carries them for every home: three letters, width, length,
    # bedrooms, variant letter (ELT32685B = 32 x 68, 5 bed). The bed digit
    # matches the page on all 18, which is what makes reading width and length
    # from the same code safe.
    #
    # POPULAR OPTIONS are options, not standard features, and carry no prices,
    # so they go in raw rather than features. A listing that said "Stainless
    # Steel Appliances" as standard on a home that ships black would be wrong.
    class JessupHousingAdapter < BaseAdapter
      SITEMAP_PATH = '/page-sitemap.xml'
      SERIES_SEGMENT_RE = /\A[a-z0-9-]+-series\z/
      MODEL_ID_RE  = /\A[A-Z]{3}\d{5}[A-Z]?\z/
      MODEL_CODE_RE = /\A[A-Z]{3}(\d{2})(\d{2})(\d)/
      SPEC_RE = /(\d+)\s*Bed\w*\s*\|\s*([\d.]+)\s*Bath\w*\s*\|\s*([\d,]+)\s*Square\s*F/i
      SIZE_IN_NAME_RE = /\s+(\d{2})\s*[xX×]\s*(\d{2,3})\s*\z/
      OPTIONS_HEADING = 'POPULAR OPTIONS'
      # Section headings on the page that are not feature groups.
      NON_FEATURE_HEADINGS = %w[FLOORPLAN GALLERY FEATURES].freeze
      SINGLE_WIDE_MAX = 18
      # Tours are linked two ways: the embeddable show/?m=ID and the account
      # page models/ID, which does not embed. Both normalize to show/?m=ID.
      MATTERPORT_RE = %r{https?://(?:my\.)?matterport\.com/(?:show/?\?(?:[^"'\s<>]*&)?m=|models/)([A-Za-z0-9]{8,})}i

      # robots.txt asks for Crawl-delay: 10. Eighteen homes is three minutes.
      def crawl_delay
        Integer(source.config['crawl_delay'] || 10)
      end

      def discover(limit: nil)
        @urls = {}
        keys = sitemap_urls.filter_map { |url| register(url) }.uniq
        limit ? keys.first(limit) : keys
      end

      def fetch(key)
        url = (@urls || {})[key.to_s] || key.to_s
        { key: key.to_s, url: url, html: http_get(url) }
      end

      def parse(raw)
        doc = raw[:html].present? ? Nokogiri::HTML(raw[:html]) : nil
        doc&.css('script, style, noscript')&.remove
        content = doc&.at_css('.entry-content') || doc
        headings = heading_texts(content)
        name_line = headings.first
        model_id = headings.find { |h| h.match?(MODEL_ID_RE) }
        beds, baths, sqft = spec_line(content)
        width, length = dimensions_for(name_line, model_id)

        NormalizedHome.new(
          source_key:    raw[:key].presence || slug_key(raw[:url]),
          source_url:    raw[:url],
          model_name:    model_name(name_line),
          model_id:      model_id,
          series:        series_for(raw[:url]),
          property_type: width ? [width <= SINGLE_WIDE_MAX ? 'Single Wide' : 'Double Wide'] : [],
          bedrooms:      beds,
          bathrooms:     baths,
          dimensions:    (width && length ? "#{width}x#{length}" : nil),
          square_feet:   sqft,
          description:   nil, # the site publishes no descriptive copy
          features:      features(content),
          images:        images(content),
          virtual_tour_url: matterport(raw[:html]),
          raw: {
            'floorplan_pdf_url' => floorplan_pdf(content),
            'popular_options'   => popular_options(content).presence
          }.compact
        )
      end

      def diagnostics
        url   = sitemap_url
        probe = http_probe(url, accept: 'application/xml,text/xml')
        out = { adapter: 'jessup_housing', sitemap_url: url, status: probe[:status], bytes: probe[:bytes],
                redirect: probe[:location], server: probe[:server], content_type: probe[:content_type] }
        out[:error] = probe[:error] if probe[:error]
        if probe[:body].present?
          out[:home_page_count] = home_urls_in(probe[:body]).size
          out[:looks_blocked]   = looks_blocked?(probe[:body])
        end
        out
      end

      private

      def sitemap_url
        source.config['sitemap_url'].presence || "#{site_root}#{SITEMAP_PATH}"
      end

      def sitemap_urls
        body = http_get(sitemap_url, accept: 'application/xml,text/xml')
        # An empty sitemap would read as "every home was removed" and
        # inactivate the whole catalog on every subscribed dealer.
        raise "no sitemap at #{sitemap_url}" if body.blank?

        home_urls_in(body)
      end

      def home_urls_in(xml)
        Nokogiri::XML(xml).remove_namespaces!.css('url > loc').map { |n| n.text.strip }.select do |loc|
          segs = URI.parse(loc).path.split('/').reject(&:blank?)
          segs.size == 2 && segs.first.match?(SERIES_SEGMENT_RE)
        rescue URI::InvalidURIError
          false
        end
      end

      def register(url)
        key = slug_key(url)
        return nil if key.blank?

        @urls[key] = url
        key
      end

      def slug_key(url)
        URI.parse(url.to_s).path.split('/').reject(&:blank?).last
      rescue URI::InvalidURIError
        nil
      end

      def site_root
        uri = URI.parse(source.base_url.to_s)
        "#{uri.scheme}://#{uri.host}"
      end

      def heading_texts(content)
        return [] if content.nil?

        content.css('.fl-heading-text').map { |n| clean(n.text) }.reject(&:blank?)
      end

      def clean(text)
        text.to_s.tr(" ", ' ').gsub(/\s+/, ' ').strip
      end

      # "THE NIXON" -> "The Nixon"; "BAHAMA 28X76" -> "Bahama" (size goes to
      # dimensions, where every other source keeps it).
      def model_name(line)
        return nil if line.blank?

        base = line.sub(SIZE_IN_NAME_RE, '')
        base.split(' ').map { |w| w.match?(/\A[A-Z]{2,}\z/) || w == w.downcase ? w.capitalize : w }.join(' ')
      end

      def spec_line(content)
        text = content&.css('.fl-rich-text p')&.map { |p| clean(p.text) }&.find { |t| t.match?(SPEC_RE) }
        m = text.to_s.match(SPEC_RE)
        return [nil, nil, nil] unless m

        [m[1].to_i, m[2], m[3].delete(',').to_i]
      end

      def dimensions_for(name_line, model_id)
        if (m = name_line.to_s.match(SIZE_IN_NAME_RE))
          return [m[1].to_i, m[2].to_i]
        end

        m = model_id.to_s.match(MODEL_CODE_RE)
        m ? [m[1].to_i, m[2].to_i] : [nil, nil]
      end

      # "/the-elite-series/..." -> "Elite Series"
      def series_for(url)
        seg = URI.parse(url.to_s).path.split('/').reject(&:blank?).first.to_s
        return nil unless seg.match?(SERIES_SEGMENT_RE)

        seg.sub(/\Athe-/, '').split('-').map(&:capitalize).join(' ')
      rescue URI::InvalidURIError
        nil
      end

      # Each h4 heading after FEATURES owns the rich text that follows it in the
      # same column. Section => [items], the shape ingestion flattens.
      def features(content)
        sections = {}
        each_h4_list(content) do |heading, items|
          next if heading.casecmp?(OPTIONS_HEADING)

          sections[heading.split.map(&:capitalize).join(' ')] = items if items.any?
        end
        sections
      end

      def popular_options(content)
        out = []
        each_h4_list(content) { |heading, items| out.concat(items) if heading.casecmp?(OPTIONS_HEADING) }
        out
      end

      def each_h4_list(content)
        return if content.nil?

        content.css('h4.fl-heading').each do |h4|
          heading = clean(h4.text)
          next if heading.blank? || NON_FEATURE_HEADINGS.include?(heading.upcase)

          module_node = h4.ancestors('.fl-module').first
          rich = module_node&.xpath('following-sibling::*[contains(@class,"fl-module-rich-text")][1]')&.first
          yield heading, list_items(rich)
        end
      end

      def list_items(rich)
        return [] if rich.nil?

        lis = rich.css('li').map { |li| clean(li.text) }
        return lis.reject(&:blank?) if lis.any?

        rich.css('p').flat_map do |p|
          p.inner_html.split(%r{<br\s*/?>}i).map { |frag| clean(Nokogiri::HTML.fragment(frag).text).sub(/\A[•·*-]\s*/, '') }
        end.reject(&:blank?)
      end

      # Floor plan first and flagged, then the gallery at full size (the <img>
      # inside each link is a 300x200 crop). The page hero is a row background
      # shared by every home in the series, so scoping to modules excludes it.
      def images(content)
        return [] if content.nil?

        seen = {}
        plan = floorplan_img(content)
        add_image(seen, plan, is_floorplan: true) if plan

        content.css('.fl-module-gallery a[href]').each { |a| add_image(seen, a['href'], is_floorplan: false) }
        seen.values
      end

      def floorplan_img(content)
        content.css('.fl-module-photo img').each do |img|
          url = [img['data-src'], img['src']].find { |u| uploaded?(u) }
          return absolutize(url) if url
        end
        nil
      end

      def matterport(html)
        id = html.to_s[MATTERPORT_RE, 1]
        id && "https://my.matterport.com/show/?m=#{id}"
      end

      def floorplan_pdf(content)
        a = content&.css('a.fl-button[href$=".pdf"]')&.first
        a && absolutize(a['href'])
      end

      def add_image(seen, url, is_floorplan:)
        return unless uploaded?(url)

        url = absolutize(url)
        seen[url] ||= { 'source_url' => url, 'local_url' => nil, 'alt' => '', 'is_floorplan' => is_floorplan }
      end

      def uploaded?(url)
        url.to_s.include?('/wp-content/uploads/') && !url.to_s.match?(/logo|icon/i) &&
          url.to_s.match?(/\.(jpe?g|png|webp)(\?|\z)/i)
      end

      def absolutize(url)
        url.to_s.start_with?('//') ? "https:#{url}" : url.to_s
      end
    end
  end
end
