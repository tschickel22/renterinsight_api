# frozen_string_literal: true

require 'nokogiri'

module SiteProfiles
  # Reduces a page to the signal an LLM needs.
  #
  # A modern dealer site is 300 KB - 1 MB of markup, most of it Tailwind classes
  # and inline SVG. Feeding that to Claude is expensive and mostly noise. This
  # produces ~3-8 KB per page, which is what keeps a 10-page scan around 100k
  # tokens instead of millions.
  #
  # Tuned against real dealer sites (WordPress + Elementor, which is most of
  # them). Three things that a naive reading gets badly wrong:
  #
  #   1. Navigation dominates. On a typical dealer home page ~75% of <li>
  #      elements are menu items, so "every p and li" yields mostly menus:
  #      "Floor Plans All Floor Plans Singlewides Doublewides…". Chrome is
  #      stripped before prose is read.
  #   2. Nokogiri's #text concatenates nested elements with no separator, so a
  #      two-span heading reads "WELCOME TOMOBILE HOME MASTERS". Children are
  #      joined with spaces instead.
  #   3. The best photography is in CSS, not <img>. Elementor puts hero and
  #      section imagery in inline background-image, so an <img>-only reader
  #      misses exactly the images worth keeping.
  class PageDigest
    MAX_TEXT_CHARS = 6_000
    MAX_ITEMS = 40
    MIN_PARAGRAPH_CHARS = 40

    # Page furniture: real content is never inside these.
    CHROME_SELECTOR = [
      'nav', 'header', 'footer', 'aside',
      '.menu', '#menu', '.nav', '.navbar', '.navigation', '.breadcrumb',
      '.sidebar', '.widget', '.cookie', '.modal', '.popup',
      '[role="navigation"]', '[role="banner"]', '[role="contentinfo"]'
    ].join(', ')

    # Logos, flags, spacers, share icons — never the photography we want.
    JUNK_IMAGE = /logo|icon|sprite|spacer|placeholder|avatar|badge|flag|arrow|bullet|favicon|1x1|blank/i

    # Matching "background…url(…)" in one pass proved fragile — shorthand and
    # longhand backtrack differently. Collect style values first, then read any
    # url() out of them, and keep only things that look like images.
    CSS_URL = /url\(\s*(['"]?)([^)'"]+)\1\s*\)/i
    IMAGE_EXTENSION = /\.(jpe?g|png|webp|avif|gif)(\?|#|\z)/i

    Digest = Struct.new(
      :url, :title, :meta_description, :og_image, :headings, :paragraphs,
      :images, :background_images, :links, :forms, :iframes, :scripts, :text_ratio,
      keyword_init: true
    ) do
      def to_h
        super.except(:text_ratio)
      end

      # Nearly all markup and no text means we fetched a shell, not the content.
      def likely_client_rendered?
        text_ratio.to_f < 0.02
      end

      # Best-guess hero imagery, most promising first. Backgrounds outrank
      # <img> because that is where dealer sites put their photography.
      def candidate_hero_images
        (Array(background_images) + Array(images).map { |i| i[:src] }).uniq
      end
    end

    def initialize(response)
      @url = response.url
      @html = response.body.to_s
      @doc = Nokogiri::HTML(@html)

      # Read scripts/iframes before anything is stripped — vendor detection
      # runs off them and inline bootstraps go away below.
      @scripts = raw_scripts
      @iframes = raw_iframes

      # Backgrounds come from style attributes and <style> blocks, both of
      # which get removed from the content view below.
      @background_images = raw_background_images

      @doc.search('script, style, noscript, svg').each(&:remove)

      # A chrome-free view for prose. Links still come from the full document,
      # since navigation is exactly what LinkInventory needs.
      @content = @doc.dup
      @content.search(CHROME_SELECTOR).each(&:remove)
    end

    def call
      Digest.new(
        url: @url,
        title: text_of('title'),
        meta_description: attr_of('meta[name="description"]', 'content'),
        og_image: attr_of('meta[property="og:image"]', 'content'),
        headings: headings,
        paragraphs: paragraphs,
        images: images,
        background_images: @background_images,
        links: links,
        forms: forms,
        iframes: @iframes,
        scripts: @scripts,
        text_ratio: text_ratio
      )
    end

    private

    # Joins child nodes with spaces. Nokogiri's #text would run adjacent
    # elements together: "WELCOME TO" + "MOBILE HOME MASTERS" -> "WELCOME
    # TOMOBILE HOME MASTERS".
    def separated_text(node)
      return '' if node.nil?

      parts = node.children.map { |c| c.text.strip }.reject(&:empty?)
      (parts.any? ? parts.join(' ') : node.text).squish
    end

    def text_of(selector)
      @doc.at_css(selector)&.text&.strip&.presence
    end

    def attr_of(selector, attribute)
      @doc.at_css(selector)&.[](attribute)&.strip&.presence
    end

    def headings
      @content.css('h1, h2, h3').first(MAX_ITEMS).filter_map do |h|
        text = separated_text(h)
        next if text.blank?

        { level: h.name, text: text.truncate(200) }
      end
    end

    # <p> only. List items on a dealer site are overwhelmingly menus, and the
    # ones that are not are usually feature bullets already captured by the
    # surrounding heading.
    def paragraphs
      budget = MAX_TEXT_CHARS
      @content.css('p').filter_map do |p|
        break if budget <= 0

        text = separated_text(p)
        next if text.length < MIN_PARAGRAPH_CHARS

        budget -= text.length
        text.truncate(500)
      end.first(MAX_ITEMS)
    end

    def images
      @content.css('img').filter_map do |img|
        src = img['src'] || img['data-src'] || img['data-lazy-src'] || first_srcset(img)
        next if src.blank? || src.start_with?('data:')

        absolute = absolutize(src)
        next if junk_image?(absolute, img)

        {
          src: absolute,
          alt: img['alt'].to_s.squish.presence,
          width: img['width'].presence
        }.compact
      end.uniq { |i| i[:src] }.first(MAX_ITEMS)
    end

    def first_srcset(img)
      set = img['srcset'] || img['data-srcset']
      return nil if set.blank?

      # Widest candidate wins — a demo page wants the largest available.
      set.split(',').map(&:strip).max_by { |c| c[/(\d+)w/, 1].to_i }&.split(/\s+/)&.first
    end

    def junk_image?(src, node = nil)
      return true if src.match?(JUNK_IMAGE)
      return true if node && node['class'].to_s.match?(JUNK_IMAGE)

      width = node && node['width'].to_i
      width.present? && width.positive? && width < 100
    end

    def raw_iframes
      @doc.css('iframe[src]').first(20).map { |f| f['src'] }.compact
    end

    def raw_scripts
      external = @doc.css('script[src]').map { |s| s['src'] }.compact
      # Inline scripts matter for vendor detection (many widgets are inline
      # bootstraps), but only the first line or so carries the signature.
      inline = @doc.css('script:not([src])').first(20).filter_map do |s|
        body = s.text.to_s.squish
        body.presence&.truncate(300)
      end
      { external: external.first(60), inline: inline }
    end

    def raw_background_images
      sources = @doc.css('[style]').map { |n| n['style'].to_s } + @doc.css('style').map(&:text)

      sources.flat_map { |css| css.scan(CSS_URL).map { |_, raw| raw } }
             .filter_map do |raw|
               raw = raw.to_s.strip
               next if raw.blank? || raw.start_with?('data:')
               next unless raw.match?(IMAGE_EXTENSION)

               url = absolutize(raw)
               next if junk_image?(url)

               url
             end.uniq.first(MAX_ITEMS)
    end

    def links
      @doc.css('a[href]').first(300).filter_map do |a|
        href = a['href'].to_s.strip
        next if href.blank? || href.start_with?('#', 'javascript:')

        label = separated_text(a)
        { href: absolutize(href), label: label.presence&.truncate(120) }.compact
      end
    end

    def forms
      @doc.css('form').first(10).map do |form|
        {
          action: form['action'].presence,
          method: form['method'].presence,
          fields: form.css('input, select, textarea').filter_map do |field|
            next if field['type'] == 'hidden'

            {
              name: field['name'].presence,
              type: field['type'].presence || field.name,
              label: field['placeholder'].presence || field['aria-label'].presence,
              required: field['required'] ? true : nil
            }.compact
          end
        }
      end
    end

    def text_ratio
      return 0.0 if @html.empty?

      @doc.text.squish.length.to_f / @html.length
    end

    def absolutize(href)
      URI.join(@url, href).to_s
    rescue StandardError
      href
    end
  end
end
