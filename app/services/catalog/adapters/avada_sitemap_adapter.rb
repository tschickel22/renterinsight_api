# frozen_string_literal: true

module Catalog
  module Adapters
    # Adapter for WordPress/Avada sites that publish a home-details sitemap
    # (Kabco — kabcobuilders.com). SSR, no headless browser. Proves the adapter
    # interface survives a genuinely different platform.
    #
    # Identity: the page slug (last path segment) is the stable source_key.
    #
    # CALIBRATION NOTE: Avada renders specs as "counter boxes" (Bed(s), Bath(s),
    # Dimensions, Square Feet, ID, Series, Property Type) and features as 4–5
    # accordion sections with doubled headings. Name comes from og:title (strip
    # " • Kabco Builders") — NOT the <h1>, which holds accordion headings.
    # Gallery prefers data-orig-src (lazy-loaded). Verify against live HTML.
    class AvadaSitemapAdapter < BaseAdapter
      MATTERPORT_RE = %r{https?://(?:my\.)?matterport\.com/show/\?[^\s"'<>)]*m=[A-Za-z0-9]+[^\s"'<>)]*}i
      TITLE_SUFFIX_RE = /\s*[•|]\s*Kabco Builders\s*\z/i

      def crawl_delay
        Integer(source.config['crawl_delay'] || 10) # robots.txt: 10s
      end

      def discover(limit: nil)
        @urls ||= {}
        sitemap_url = source.config['sitemap_url'].presence ||
                      "#{base_url}/home-details-sitemap.xml"
        body = http_get(sitemap_url, accept: 'application/xml,text/xml')
        return [] if body.blank?

        keys = Nokogiri::XML(body).remove_namespaces!.css('url > loc').map(&:text)
                       .reject { |loc| loc.match?(%r{/homes/?\z}) } # drop the index page
                       .filter_map do |loc|
                         slug = slug_for(loc)
                         next if slug.blank?

                         @urls[slug] = loc
                         slug
                       end.uniq
        limit ? keys.first(limit) : keys
      rescue StandardError => e
        Rails.logger.warn "[#{self.class.name}] sitemap discovery failed: #{e.message}"
        []
      end

      def fetch(key)
        # Discovery caches the full sitemap URL; the fallback is the canonical
        # /home-details/{slug}/ path.
        url  = (@urls || {})[key] || "#{base_url}/home-details/#{key}/"
        html = http_get(url)
        { key: key.to_s, url: url, html: html }
      end

      def parse(raw)
        doc  = raw[:html].present? ? Nokogiri::HTML(raw[:html]) : nil
        # Drop scripts/styles so inline CSS can't poison text/number scans.
        doc&.css('script, style, noscript')&.remove
        html = raw[:html].to_s

        NormalizedHome.new(
          source_key:       raw[:key],
          source_url:       raw[:url],
          model_name:       extract_name(doc),
          model_id:         counter_box(doc, %w[id model]),
          series:           counter_box(doc, %w[series]),
          property_type:    extract_property_type(doc),
          bedrooms:         to_int(counter_box(doc, ['bed', 'bed(s)', 'bedrooms'])),
          bathrooms:        to_decimal(counter_box(doc, ['bath', 'bath(s)', 'bathrooms'])),
          dimensions:       counter_box(doc, %w[dimensions]),
          square_feet:      to_int(counter_box(doc, ['square feet', 'sq ft', 'sqft'])),
          description:      extract_description(doc),
          features:         extract_features(doc),
          images:           extract_images(doc),
          virtual_tour_url: scan_regex(html, MATTERPORT_RE),
          price_quote_url:  nil,
          raw: { 'disclaimer' => extract_disclaimer(doc) }
        )
      end

      private

      def extract_name(doc)
        og = doc&.at_css('meta[property="og:title"]')&.[]('content')
        og.to_s.sub(TITLE_SUFFIX_RE, '').strip.presence
      end

      # Avada renders each spec as a column whose text is "<value><label>"
      # concatenated, e.g. "4Bed(s)", "2280Square Feet", "Double WideProperty
      # Type", "MD-66-32ID". We locate the LABEL element (an exact-text node),
      # walk up to its layout column, and strip the trailing label to get the
      # value.
      def counter_box(doc, labels)
        return nil if doc.nil?

        wanted     = labels.map { |l| l.downcase.strip }
        label_node = doc.css('p, span, h3, h4, h5').find do |n|
          t = n.text.strip
          t.length < 20 && wanted.include?(t.downcase)
        end

        if label_node
          column = label_node.ancestors.find { |a| a['class'].to_s =~ /fusion-layout-column|fusion_builder_column/ } ||
                   label_node.parent
          full  = column.text.gsub(/\s+/, ' ').strip
          value = full.sub(/#{Regexp.escape(label_node.text.strip)}\s*\z/i, '').strip
          return value if value.present?
        end

        # Fallback: value-before-label run anywhere in the page text.
        labels.each do |l|
          m = doc.text.match(/([A-Za-z0-9][\w'".,xX×\s-]{0,18}?)\s*#{Regexp.escape(l)}/i)
          return m[1].strip if m && m[1].strip.present?
        end
        nil
      end

      # Property type is a free-text counter-box value (e.g. "Double Wide",
      # "Single Wide", "Manufactured") — return it verbatim as a 1-element array.
      def extract_property_type(doc)
        value = counter_box(doc, ['property type'])
        value.present? ? [value] : []
      end

      # og/meta description first; these Avada pages often have neither, so fall
      # back to the longest real on-page paragraph (the home's descriptive copy).
      # If markup breaks and paragraphs vanish, this correctly goes blank rather
      # than masking the break with synthesized text.
      def extract_description(doc)
        meta = doc&.at_css('meta[name="description"], meta[property="og:description"]')&.[]('content').to_s.strip
        return meta if meta.present?

        longest = doc&.css('p')&.map { |p| p.text.gsub(/\s+/, ' ').strip }
                     &.select { |t| t.length >= 60 }&.max_by(&:length)
        longest.presence
      end

      # 4–5 accordion feature sections. Bodies are <br>-separated text (not <li>),
      # so split on line breaks. De-dupe doubled headings.
      def extract_features(doc)
        return {} if doc.nil?

        features = {}
        doc.css('.fusion-toggle-heading, .fusion-accordian .panel-title, .accordion-title').each do |heading|
          title = heading.text.to_s.strip
          next if title.blank? || features.key?(title)

          body = heading.ancestors('.fusion-panel, .panel').first
          next unless body

          items = body.css('li').map { |li| li.text.strip }.reject(&:blank?)
          items = panel_lines(body) if items.empty?
          features[title] = items.uniq if items.any?
        end
        features
      end

      # Split an accordion body that uses <br> separators into individual items.
      def panel_lines(body)
        content = body.at_css('.panel-body, .fusion-panel-body, .toggle-content') || body
        html = content.inner_html.gsub(%r{<br\s*/?>}i, "\n")
        Nokogiri::HTML.fragment(html).text.split("\n").map(&:strip).reject(&:blank?)
      end

      # Gallery: prefer data-orig-src over src (lazyauto), keep /wp-content/uploads/,
      # drop Logo/Icon assets, tag floorplans by filename token.
      def extract_images(doc)
        return [] if doc.nil?

        seen = {}
        doc.css('img').each do |img|
          src = first_attr(img, %w[data-orig-src data-lazy-src src])
          next if src.blank?
          next unless src.include?('/wp-content/uploads/')
          next if src.match?(/logo|icon/i)

          seen[src] ||= {
            'source_url'   => src,
            'local_url'    => nil,
            'alt'          => img['alt'].to_s,
            'is_floorplan' => src.downcase.include?('floorplan')
          }
        end
        seen.values
      end

      def extract_disclaimer(doc)
        doc&.css('.disclaimer, [class*="disclaimer"]')&.first&.text&.strip
      end

      def slug_for(loc)
        URI.parse(loc).path.split('/').reject(&:blank?).last
      rescue StandardError
        nil
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
