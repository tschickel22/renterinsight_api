# frozen_string_literal: true

module SiteProfiles
  # Pulls logo, colours and fonts off the raw HTML/CSS.
  #
  # Deliberately not an AI call: these are mechanical facts sitting in the
  # markup, and a model asked "what colour is this brand?" will confidently
  # invent a hex code that is close but wrong.
  class BrandExtractor
    LOGO_HINT = /logo|brand|header[-_]?img/i

    # Ignore greys/near-black/near-white — every site is full of them and none
    # of them are the brand colour.
    NEUTRAL_TOLERANCE = 18

    CSS_VAR_PATTERNS = {
      primary: /--(?:brand-)?(?:color-)?primary(?:-color)?\s*:\s*(#[0-9a-f]{3,8}|rgba?\([^)]+\))/i,
      secondary: /--(?:brand-)?(?:color-)?secondary(?:-color)?\s*:\s*(#[0-9a-f]{3,8}|rgba?\([^)]+\))/i,
      accent: /--(?:brand-)?(?:color-)?accent(?:-color)?\s*:\s*(#[0-9a-f]{3,8}|rgba?\([^)]+\))/i
    }.freeze

    def initialize(pages)
      # pages: [{ html:, url:, doc: }] — needs raw HTML, so it runs alongside
      # PageDigest rather than off its output.
      @pages = Array(pages)
    end

    def call
      {
        'logo_url' => logo_url,
        'colors' => colors,
        'fonts' => fonts
      }.compact
    end

    private

    def docs
      @docs ||= @pages.filter_map do |page|
        html = page[:html] || page['html']
        next if html.blank?

        [Nokogiri::HTML(html), page[:url] || page['url']]
      end
    end

    def logo_url
      docs.each do |doc, url|
        # data-src is checked alongside src, or a lazy-loaded logo is never even
        # considered a candidate: its src is a placeholder and the filename
        # that says "logo" is in the lazy attribute.
        candidate = doc.css('header img, .header img, nav img, img').find do |img|
          [img['src'], img['data-src'], img['data-lazy-src'], img['alt'], img['class'], img['id']]
            .compact.any? { |v| v.match?(LOGO_HINT) }
        end

        # The data-src fallback below used to be unreachable: it was guarded by
        # `if candidate['src']`, so a lazy-loaded logo — which carries only
        # data-src, or a 1x1 placeholder in src — was found and then discarded.
        # Lazy loading is the default on WordPress and Elementor, which is most
        # dealer sites.
        src = logo_src(candidate)
        return absolutize(src, url) if src.present?

        og = doc.at_css('meta[property="og:logo"], meta[property="og:image"]')&.[]('content')
        return absolutize(og, url) if og.present?

        icon = doc.at_css('link[rel~="icon"], link[rel="apple-touch-icon"]')&.[]('href')
        return absolutize(icon, url) if icon.present?
      end
      nil
    end

    # A real image URL, preferring whichever attribute actually holds one.
    # An inline placeholder is not a logo, however real its src looks.
    def logo_src(img)
      return nil if img.nil?

      %w[src data-src data-lazy-src].each do |attr|
        value = img[attr].to_s.strip
        next if value.blank? || value.start_with?('data:')

        return value
      end
      nil
    end

    def colors
      found = {}

      raw_css.then do |css|
        CSS_VAR_PATTERNS.each do |key, pattern|
          match = pattern.match(css)
          next if match.nil?

          value = normalize(match[1])
          # A neutral is not a brand colour, whatever the variable is called.
          #
          # WordPress and Elementor themes ship generic --primary: #000 and
          # --secondary: #fff, so a dealer whose actual brand is a strong blue
          # came back as black and white. That is not merely wrong: the footer
          # takes its background from the secondary, so an extracted #ffffff
          # produced a white-on-white footer, and the same value prints prices
          # onto white cards.
          #
          # Measured on a real dealer site: these patterns matched #000000 and
          # #ffffff while the site's own blue, #1e99fb, was the most common
          # non-neutral colour in the same stylesheet.
          next if value.blank? || neutral?(value)

          found[key.to_s] = value
        end
      end

      # Fall back to the most common non-neutral colour in the stylesheet — for
      # most dealer sites that IS the brand colour.
      if found['primary'].blank?
        found['primary'] = dominant_color
      end

      found.compact.presence
    end

    def raw_css
      @raw_css ||= docs.flat_map do |doc, _url|
        doc.css('style').map(&:text) + doc.css('[style]').map { |n| n['style'] }
      end.join("\n")
    end

    def dominant_color
      counts = Hash.new(0)
      raw_css.scan(/#(?:[0-9a-f]{3}|[0-9a-f]{6})\b/i) do |_|
        hex = Regexp.last_match(0)
        normalized = normalize(hex)
        next if normalized.nil? || neutral?(normalized)

        counts[normalized] += 1
      end
      counts.max_by { |_, v| v }&.first
    end

    def fonts
      families = raw_css.scan(/font-family\s*:\s*([^;}"']+)/i).flatten
      google = docs.flat_map do |doc, _|
        doc.css('link[href*="fonts.googleapis.com"]').map { |l| l['href'] }
      end.compact

      google_families = google.flat_map do |href|
        href.scan(/family=([^&:]+)/).flatten.map { |f| CGI.unescape(f).tr('+', ' ') }
      end

      primary = google_families.first || families.first&.split(',')&.first&.strip&.delete('"\'')
      return nil if primary.blank?

      { 'heading' => primary, 'body' => primary }
    end

    def normalize(value)
      value = value.to_s.strip.downcase
      return nil if value.blank?

      if value.start_with?('#')
        hex = value.delete('#')
        hex = hex.chars.map { |c| c * 2 }.join if hex.length == 3
        return nil unless hex.length >= 6

        "##{hex[0, 6]}"
      elsif value.start_with?('rgb')
        parts = value.scan(/\d+/).first(3).map(&:to_i)
        return nil unless parts.size == 3

        format('#%02x%02x%02x', *parts)
      end
    end

    def neutral?(hex)
      r, g, b = hex.delete('#').scan(/../).map { |c| c.to_i(16) }
      return true if r.nil?

      (r - g).abs <= NEUTRAL_TOLERANCE &&
        (g - b).abs <= NEUTRAL_TOLERANCE &&
        (r - b).abs <= NEUTRAL_TOLERANCE
    end

    def absolutize(href, base)
      return nil if href.blank?

      URI.join(base.to_s, href).to_s
    rescue StandardError
      href
    end
  end
end
