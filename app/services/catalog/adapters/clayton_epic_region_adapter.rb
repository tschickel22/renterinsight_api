# frozen_string_literal: true

module Catalog
  module Adapters
    # Adapter for Clayton Homes' "Epic Experience" national site
    # (claytonepicexperience.com). Homes are partitioned across six geographic
    # regions and a dealer only has access to specific ones, so each region is
    # one CatalogSource — analogous to Tru Origin / Tru Mini being separate
    # sources on the shared owntru.com domain.
    #
    # base_url shape: https://claytonepicexperience.com/homes/?region={1..6}
    #   1 West, 2 Central, 3 South, 4 East, 5 North, 6 North-Central
    #
    # Detail pages: /models/{slug}/ — same URL pattern as TRU but a different
    # theme (chbg-epic-national vs chbg-tru), so the top-level <h1> is NOT
    # wrapped in <section class="page-title">, and the spec line is bullet-
    # separated ("2 beds • 2 baths • 1,020 sq. ft. • 16x68") including
    # dimensions inline.
    #
    # Cloudflare-fronted: BaseAdapter#http_get with a browser UA already gets
    # through in local testing. If we see 403s from a datacenter IP, we'll
    # need to add Accept-Language / cookie handling before considering a
    # headless-browser fallback.
    class ClaytonEpicRegionAdapter < BaseAdapter
      REGIONS = {
        1 => 'West',
        2 => 'Central',
        3 => 'South',
        4 => 'East',
        5 => 'North',
        6 => 'North-Central'
      }.freeze

      SPEC_RE = /
        (?<bed>\d+)\s*beds?\s*[•·|]\s*
        (?<bath>\d+(?:\.\d+)?)\s*baths?\s*[•·|]\s*
        (?<sqft>[\d,]+)\s*sq\.?\s*ft\.?
        (?:\s*[•·|]\s*(?<dims>\d+\s*[xX×]\s*\d+))?
      /ix

      MODEL_HREF_RE     = %r{https?://[^/]+/models/([a-z0-9\-]+)/?}i
      # Clayton SKUs share a common tail encoding — width (2 digits), length
      # (2 digits), bedroom count (1 digit), 2-letter model suffix. The brand
      # prefix varies (TRU brands are pure letters like "TRT"; Epic uses a
      # mixed alnum prefix like "43CEE" that appears to encode the region).
      # Anchor to the tail so both families decode.
      SKU_RE            = /(?<width>\d{2})(?<length>\d{2})(?<beds>\d)(?<suffix>[A-Z]{2})\z/
      CLAYTON_IMG_HOST  = 'api.claytonhomes.com'
      TOUR_HOSTS_RE     = %r{https?://(?:my\.)?(?:matterport\.com|momento360\.com)/[^\s"'<>)]+}i
      TITLE_SUFFIX_RE   = /\s*-\s*Clayton Epic Experience\s*\z/i

      def crawl_delay
        Integer(source.config['crawl_delay'] || 5)
      end

      def discover(limit: nil)
        @urls ||= {}
        html = http_get(base_url)
        return [] if html.blank?

        keys = Nokogiri::HTML(html).css('a[href*="/models/"]').filter_map do |a|
          m = a['href'].to_s.match(MODEL_HREF_RE)
          next unless m
          slug = m[1].to_s.downcase.strip
          next if slug.blank?

          @urls[slug] = "#{site_root}/models/#{slug}/"
          slug
        end.uniq
        limit ? keys.first(limit) : keys
      rescue StandardError => e
        Rails.logger.warn "[#{self.class.name}] discovery failed: #{e.message}"
        []
      end

      def fetch(key)
        url  = (@urls || {})[key] || "#{site_root}/models/#{key}/"
        html = http_get(url)
        { key: key.to_s, url: url, html: html }
      end

      def parse(raw)
        doc = raw[:html].present? ? Nokogiri::HTML(raw[:html]) : nil
        doc&.css('script, style, noscript')&.remove
        html = raw[:html].to_s

        specs  = extract_specs(doc)
        sku_id = raw[:key].to_s.upcase.presence
        sku    = decode_sku(sku_id)

        NormalizedHome.new(
          source_key:       raw[:key],
          source_url:       raw[:url],
          model_name:       extract_name(doc),
          model_id:         sku_id,
          series:           region_label,
          property_type:    sku ? [sku[:property_type]] : [],
          bedrooms:         specs[:bedrooms],
          bathrooms:        specs[:bathrooms],
          dimensions:       specs[:dimensions] || (sku ? sku[:dimensions] : nil),
          square_feet:      specs[:square_feet],
          description:      nil,
          features:         {},
          images:           extract_images(doc),
          virtual_tour_url: scan_regex(html, TOUR_HOSTS_RE),
          video_url:        nil,
          price_quote_url:  nil,
          raw: { 'disclaimer' => extract_disclaimer(doc), 'region_id' => region_id }
        )
      end

      def diagnostics
        probe = http_probe(base_url)
        out = {
          adapter:      'clayton_epic_region',
          region_id:    region_id,
          region_label: region_label,
          listing_url:  base_url,
          http_status:  probe[:status],
          bytes:        probe[:bytes],
          redirect:     probe[:location]
        }
        out[:error] = probe[:error] if probe[:error]
        if probe[:body].present?
          out[:model_link_count] = probe[:body].scan(%r{/models/[a-z0-9\-]+/?"}i).size
          out[:looks_blocked]    = looks_blocked?(probe[:body])
        end
        out
      end

      private

      # The Epic theme puts the model name in a bare top-level <h1> (no
      # section.page-title wrapper). Fall back to og:title parsed as
      # "SKU :: NAME - Clayton Epic Experience".
      def extract_name(doc)
        h1 = doc&.css('h1')&.map { |n| n.text.strip }&.find(&:present?)
        return h1 if h1.present?

        og = doc&.at_css('meta[property="og:title"]')&.[]('content').to_s
        og.split('::', 2).last.to_s.sub(TITLE_SUFFIX_RE, '').strip.presence
      end

      # "2 beds • 2 baths • 1,020 sq. ft. • 16x68"
      # Dimensions are inline in the listing spec, so grab them here if present
      # and fall back to the SKU decode when they're not.
      def extract_specs(doc)
        text = doc&.at_css('div.model-specs')&.text.to_s
        text = doc&.text.to_s if text.strip.empty?
        m = text.match(SPEC_RE)
        return { bedrooms: nil, bathrooms: nil, square_feet: nil, dimensions: nil } unless m

        {
          bedrooms:    m[:bed].to_i,
          bathrooms:   m[:bath],
          square_feet: m[:sqft].delete(',').to_i,
          dimensions:  m[:dims]&.gsub(/\s+/, '')
        }
      end

      # Same Clayton SKU convention Tru uses — 43CEE16682AH -> 16ft x 68ft,
      # 2 bedrooms. Width >= 20 signals a double-wide.
      def decode_sku(sku)
        return nil if sku.blank?
        m = sku.match(SKU_RE)
        return nil unless m

        width  = m[:width].to_i
        length = m[:length].to_i
        {
          dimensions:    "#{width}x#{length}",
          property_type: width >= 20 ? 'Double Wide' : 'Single Wide'
        }
      end

      def extract_images(doc)
        return [] if doc.nil?

        seen = {}
        # Listing cards use CSS background-image URLs while the gallery uses
        # <img>. Pull both and let source_url dedupe them.
        img_srcs = doc.css('img').map { |i| clean_src(first_attr(i, %w[data-src data-lazy-src src])) }
        bg_srcs  = doc.css('[style*="background-image"]').map do |n|
          clean_src(n['style'].to_s.match(%r{background-image:\s*url\((['"]?)(.*?)\1\)})&.[](2))
        end
        (img_srcs + bg_srcs).compact.each do |src|
          next unless src.include?(CLAYTON_IMG_HOST)
          next if src.match?(/logo|icon/i)

          seen[src] ||= {
            'source_url'   => src,
            'local_url'    => nil,
            'alt'          => nil,
            # Clayton segments floorplan imagery under /images/mfg/flp/ in the
            # CDN path — reliable across sites in the family.
            'is_floorplan' => src.include?('/images/mfg/flp/')
          }
        end
        seen.values
      end

      def clean_src(src)
        return nil if src.blank?
        src.to_s.split('?').first
      end

      def extract_disclaimer(doc)
        doc&.css('.disclaimer, [class*="disclaimer"]')&.first&.text&.strip
      end

      def site_root
        uri = URI.parse(source.base_url.to_s)
        "#{uri.scheme}://#{uri.host}"
      rescue StandardError
        source.base_url.to_s.sub(%r{/+\z}, '')
      end

      # The region parameter drives everything — pull it from base_url first
      # (single source of truth) with an explicit config override as escape
      # hatch if Clayton ever changes their URL scheme.
      def region_id
        override = source.config['region_id']
        return override.to_i if override.present?

        URI.parse(source.base_url.to_s).query.to_s.split('&').each do |pair|
          k, v = pair.split('=', 2)
          return v.to_i if k == 'region' && v.present?
        end
        nil
      rescue StandardError
        nil
      end

      def region_label
        REGIONS[region_id]
      end
    end
  end
end
