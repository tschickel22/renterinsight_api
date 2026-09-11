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

        # The raw markup travels alongside the parsed document because the
        # inline-SVG search has to re-parse it with the HTML5 parser , see
        # inline_svg_logo.
        [Nokogiri::HTML(html), page[:url] || page['url'], html]
      end
    end

    def logo_url
      docs.each do |doc, url, html|
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

        # A logo drawn as an inline <svg> rather than fetched as an image.
        #
        # There is no URL to absolutize, so every check above walks straight
        # past it and the site falls through to og:image — which on a dealer
        # site is a photograph of a home, not the mark. Every Trove-built site
        # we have looked at does this, and we are asked to scan a lot of them.
        inline = inline_svg_logo(html)
        return inline if inline.present?

        og = doc.at_css('meta[property="og:logo"], meta[property="og:image"]')&.[]('content')
        return absolutize(og, url) if og.present?

        icon = doc.at_css('link[rel~="icon"], link[rel="apple-touch-icon"]')&.[]('href')
        return absolutize(icon, url) if icon.present?
      end
      nil
    end

    # Serialise a header <svg> into a data: URI the renderer can put in an <img>.
    #
    # Kept small on purpose: a mark is a few hundred bytes of paths, while an
    # inline illustration or an icon sprite runs to tens of kilobytes and is not
    # a logo. Anything over the cap is left alone rather than carried into every
    # projection of the profile.
    MAX_INLINE_SVG_BYTES = 32_768

    # Icons live in headers too, and they outnumber logos.
    #
    # Measured on thehomeplus.com: every <svg> in that header is a 14-28px
    # chevron or social glyph, and the actual mark is an <img>. So an inline SVG
    # is taken as the logo ONLY on positive evidence , it says logo or brand, or
    # it is what the home link is made of , and never on mere presence.
    ICON_CONTEXT = /menu|hamburger|search|cart|close|toggle|social|facebook|instagram|arrow|chevron/i

    # Icon sizings. A mark is drawn at header height; a glyph is drawn at the
    # size of the text beside it.
    ICON_SIZE = /\A(?:1(?:\.\d+)?em|0?\.\d+em|(?:[0-9]|[12][0-9]|3[0-2])(?:px)?)\z/i

    def inline_svg_logo(html)
      # HTML5 rather than Nokogiri::HTML, and this is not a preference.
      #
      # The HTML4 parser lowercases every attribute, so viewBox becomes viewbox
      # and <linearGradient> becomes <lineargradient>. SVG is case sensitive:
      # a mark serialised that way loses its coordinate system and draws at the
      # wrong size or not at all. The HTML5 parser applies the spec's foreign-
      # content adjustments and gives the casing back.
      doc = Nokogiri::HTML5(html)

      svg = doc.css('header svg, [class*="header"] svg, nav svg, [class*="logo"] svg').find do |node|
        context = [node['class'], node['id'], node['aria-label'], node.parent&.[]('class'),
                   node.parent&.[]('aria-label'), node.parent&.parent&.[]('class')].compact.join(' ')
        next false if context.match?(ICON_CONTEXT)
        next false if icon_sized?(node)
        next false unless context.match?(LOGO_HINT) || home_link_mark?(node)

        node.to_xml.bytesize <= MAX_INLINE_SVG_BYTES
      end
      return nil if svg.nil?

      "data:image/svg+xml;base64,#{Base64.strict_encode64(standalone_svg(svg))}"
    rescue StandardError
      nil
    end

    def icon_sized?(node)
      %w[width height].any? { |attr| node[attr].to_s.strip.match?(ICON_SIZE) }
    end

    # The mark a site puts in the link back to its own front page. A dealer site
    # that draws its logo inline puts it here and nowhere else.
    def home_link_mark?(node)
      link = node.ancestors('a').first
      return false if link.nil?

      href = link['href'].to_s.strip
      ['/', '', '#', './'].include?(href) || href.match?(%r{\Ahttps?://[^/]+/?\z})
    end

    # An SVG fragment lifted out of a page is not yet a document an <img> will
    # draw: the HTML5 parser prefixes every element (<svg:path>), and the
    # namespaces those prefixes refer to are declared on the page's root rather
    # than on the fragment.
    def standalone_svg(node)
      markup = node.to_xml.gsub(%r{<(/?)svg:}, '<\1')
      markup = markup.sub('<svg', '<svg xmlns="http://www.w3.org/2000/svg"') unless markup.match?(/<svg[^>]*\sxmlns=/)
      if markup.include?('xlink:') && !markup.include?('xmlns:xlink')
        markup = markup.sub('<svg', '<svg xmlns:xlink="http://www.w3.org/1999/xlink"')
      end
      markup
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

    # Absolute, and at the size the client actually has rather than the size
    # their header lays out. Every caller here , logo, og:image, favicon , wants
    # the original: a mark captured at 188x96 is soft in any header that shows
    # it larger, and ours does.
    def absolutize(href, base)
      return nil if href.blank?

      ImageUrl.full_size(URI.join(base.to_s, href).to_s)
    rescue StandardError
      href
    end
  end
end
