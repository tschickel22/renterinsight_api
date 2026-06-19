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
        url  = (@urls || {})[key] || "#{base_url}/homes/#{key}/"
        html = http_get(url)
        { key: key.to_s, url: url, html: html }
      end

      def parse(raw)
        doc  = raw[:html].present? ? Nokogiri::HTML(raw[:html]) : nil
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

      # Avada counter boxes: a label node and a value node within the same box.
      def counter_box(doc, labels)
        return nil if doc.nil?

        box = doc.css('.fusion-counter-box, .counter-box, [class*="counter"]').find do |b|
          labels.any? { |l| b.text.to_s.downcase.include?(l.downcase) }
        end
        if box
          value = box.at_css('.counter-value, [class*="value"], .fusion-counter-box-content')&.text&.strip
          return value if value.present?

          digits = box.text[/[\d'".,xX×\s]{1,}/]
          return digits.strip if digits.present?
        end

        labels.each do |l|
          m = doc.text.match(/#{Regexp.escape(l)}\s*[:\-]?\s*([0-9][0-9'".,xX×\s]*)/i)
          return m[1].strip if m
        end
        nil
      end

      def extract_property_type(doc)
        raw = counter_box(doc, %w[property type])
        raw.to_s.scan(/manufactured|modular/i).map(&:capitalize).uniq
      end

      def extract_description(doc)
        doc&.at_css('meta[name="description"], meta[property="og:description"]')&.[]('content')&.strip
      end

      # 4–5 accordion feature sections; de-dupe doubled headings.
      def extract_features(doc)
        return {} if doc.nil?

        features = {}
        doc.css('.fusion-accordian .panel-title, .accordion-title, .fusion-toggle-heading').each do |heading|
          title = heading.text.to_s.strip
          next if title.blank? || features.key?(title)

          body = heading.ancestors('.fusion-panel, .panel').first
          items = body&.css('li')&.map { |li| li.text.strip }&.reject(&:blank?)&.uniq || []
          features[title] = items if items.any?
        end
        features
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
