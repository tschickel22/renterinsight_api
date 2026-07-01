# frozen_string_literal: true

module Catalog
  module Adapters
    # Adapter for Clayton Home Building Group's TRU brand site (owntru.com).
    # TRU splits its lineup into two model lines that live at parallel URLs:
    #   https://owntru.com/model-lines/tru-origin/
    #   https://owntru.com/model-lines/tru-mini/
    # Each line is one CatalogSource; base_url points at the listing page and
    # discovery walks the model cards on that page (not the site-wide sitemap,
    # which merges both lines and can't tell them apart).
    #
    # Detail pages live at /models/{slug}/ under the chbg-tru WordPress theme
    # (not Avada). SSR, no headless browser needed.
    #
    # CALIBRATION NOTE: name in <h1> inside <section class="page-title">, specs
    # in <div class="model-specs"> as "X beds / Y baths / Z sq.ft.", images
    # served from api.claytonhomes.com/images/mfg/, floorplan images live inside
    # <section id="floor_plan">, virtual tour is a Momento360 iframe inside
    # <section id="tour">. Verify against live HTML before rescoping.
    class TruModelLineAdapter < BaseAdapter
      SPEC_RE           = /(?<bed>\d+)\s*beds?\s*\/\s*(?<bath>\d+(?:\.\d+)?)\s*baths?\s*\/\s*(?<sqft>[\d,]+)\s*sq\.?\s*ft\.?/i
      MODEL_HREF_RE     = %r{https?://[^/]+/models/([a-z0-9\-]+)/?}i
      # Clayton SKU encoding: 2–4 letter brand prefix, width (2 digits), length
      # (2 digits), bedroom count (1 digit), 2-letter model suffix.
      # e.g. TRT14562EH -> width 14ft, length 56ft, 2 bedrooms.
      SKU_RE            = /\A([A-Z]{2,4})(\d{2})(\d{2})(\d)([A-Z]{2})\z/
      CLAYTON_IMG_HOST  = 'api.claytonhomes.com'
      TOUR_HOSTS_RE     = %r{https?://(?:my\.)?(?:matterport\.com|momento360\.com)/[^\s"'<>)]+}i

      def crawl_delay
        Integer(source.config['crawl_delay'] || 5)
      end

      # Discovery walks the model-line listing page (base_url) and returns the
      # slugs of every /models/{slug}/ link on it. Excludes the root "/models/"
      # stub link, which shows up on every card as a fallback.
      def discover(limit: nil)
        @urls ||= {}
        html = http_get(base_url)
        return [] if html.blank?

        doc = Nokogiri::HTML(html)
        keys = doc.css('a[href*="/models/"]').filter_map do |a|
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
        doc  = raw[:html].present? ? Nokogiri::HTML(raw[:html]) : nil
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
          series:           series_from_base_url,
          property_type:    sku ? [sku[:property_type]] : [],
          bedrooms:         specs[:bedrooms],
          bathrooms:        specs[:bathrooms],
          dimensions:       sku ? sku[:dimensions] : nil,
          square_feet:      specs[:square_feet],
          description:      nil,
          features:         {},
          images:           extract_images(doc),
          virtual_tour_url: extract_virtual_tour(doc, html),
          video_url:        nil,
          price_quote_url:  nil,
          raw: { 'disclaimer' => extract_disclaimer(doc) }
        )
      end

      # Explains a zero-discovery result: did the listing page load, how many
      # /models/ links did we actually see?
      def diagnostics
        probe = http_probe(base_url)
        out = {
          adapter:      'tru_model_line',
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

      # The <h1> lives inside <section class="page-title"> and is just the model
      # name (e.g. "ELM"), no suffix. Fall back to og:title parsed as
      # "SKU :: NAME - TRU" if the h1 disappears.
      def extract_name(doc)
        h1 = doc&.at_css('section.page-title h1')&.text&.strip
        return h1 if h1.present?

        og = doc&.at_css('meta[property="og:title"]')&.[]('content').to_s
        og.split('::', 2).last.to_s.sub(/-\s*TRU\s*\z/i, '').strip.presence
      end

      # "2 beds / 1 baths / 737 sq.ft." rendered as plain text inside
      # <div class="model-specs">. If markup changes, fall back to scanning the
      # whole page for the same pattern so we degrade gracefully.
      def extract_specs(doc)
        text = doc&.at_css('div.model-specs')&.text.to_s
        text = doc&.text.to_s if text.strip.empty?
        m = text.match(SPEC_RE)
        return { bedrooms: nil, bathrooms: nil, square_feet: nil } unless m

        {
          bedrooms:    m[:bed].to_i,
          bathrooms:   m[:bath],
          square_feet: m[:sqft].delete(',').to_i
        }
      end

      # Tru's site publishes no dimensions or property-type fields on the model
      # page, but the SKU itself encodes both. Decode when the format matches;
      # return nil (adapter falls back to blank) when it doesn't so we degrade
      # gracefully if Clayton ever renames a model.
      def decode_sku(sku)
        return nil if sku.blank?
        m = sku.match(SKU_RE)
        return nil unless m

        width  = m[2].to_i
        length = m[3].to_i
        {
          dimensions:    "#{width}x#{length}",
          property_type: width >= 20 ? 'Double Wide' : 'Single Wide'
        }
      end

      # Series comes from the CatalogSource's base_url path, since each line
      # has its own listing page (/model-lines/tru-origin/, /model-lines/tru-mini/).
      # Humanize the slug so "tru-origin" -> "Tru Origin".
      def series_from_base_url
        segment = URI.parse(source.base_url.to_s).path.split('/').reject(&:blank?).last
        return nil if segment.blank?
        segment.split('-').map(&:capitalize).join(' ')
      rescue StandardError
        nil
      end

      # Clayton serves all model imagery from api.claytonhomes.com/images/mfg/,
      # partitioned into /ext/ (exterior + floorplans) and /int/ (interior).
      # Floorplans are the images that appear inside <section id="floor_plan">,
      # so tag them by containment rather than by filename or path.
      def extract_images(doc)
        return [] if doc.nil?

        floorplan_srcs = doc.css('section#floor_plan img').map { |i| clean_src(i['src']) }.compact.to_set

        seen = {}
        doc.css('img').each do |img|
          src = clean_src(img['src'])
          next if src.blank?
          next unless src.include?(CLAYTON_IMG_HOST)
          next if src.match?(/logo|icon/i)

          seen[src] ||= {
            'source_url'   => src,
            'local_url'    => nil,
            'alt'          => img['alt'].to_s,
            'is_floorplan' => floorplan_srcs.include?(src)
          }
        end
        seen.values
      end

      # Strip Clayton's ?width=NNN transform so the same image at different
      # widths dedupes and floorplan detection compares apples to apples.
      def clean_src(src)
        return nil if src.blank?
        src.to_s.split('?').first
      end

      # Momento360 (or occasionally Matterport) tour URL — pulled from the
      # iframe inside <section id="tour">, with the copy-to-clipboard data-ctc
      # attribute as fallback.
      def extract_virtual_tour(doc, html)
        iframe = doc&.at_css('section#tour iframe')&.[]('src')
        return iframe if iframe.present?

        data_ctc = doc&.at_css('section#tour a[data-ctc]')&.[]('data-ctc')
        return data_ctc if data_ctc.present?

        scan_regex(html, TOUR_HOSTS_RE)
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
    end
  end
end
