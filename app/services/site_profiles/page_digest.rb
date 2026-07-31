# frozen_string_literal: true

require 'nokogiri'

module SiteProfiles
  # Reduces a page to the signal an LLM needs.
  #
  # A modern dealer site is 300 KB - 1 MB of markup, most of it Tailwind classes
  # and inline SVG. Feeding that to Claude is expensive and mostly noise. This
  # produces ~3-8 KB per page, which is what keeps a 10-page scan around 100k
  # tokens instead of millions.
  class PageDigest
    MAX_TEXT_CHARS = 6_000
    MAX_ITEMS = 40

    Digest = Struct.new(
      :url, :title, :meta_description, :og_image, :headings, :paragraphs,
      :images, :links, :forms, :iframes, :scripts, :text_ratio,
      keyword_init: true
    ) do
      def to_h
        super.except(:text_ratio)
      end

      # A page that is nearly all markup and no text is almost certainly
      # client-rendered — we fetched the shell, not the content.
      def likely_client_rendered?
        text_ratio.to_f < 0.02
      end
    end

    def initialize(response)
      @url = response.url
      @html = response.body.to_s
      @doc = Nokogiri::HTML(@html)

      # Capture script/iframe signatures BEFORE stripping them, since vendor
      # detection runs off these and inline bootstraps are removed below.
      @scripts = raw_scripts
      @iframes = raw_iframes
      @doc.search('script, style, noscript, svg').each(&:remove)
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
        links: links,
        forms: forms,
        iframes: iframes,
        scripts: scripts,
        text_ratio: text_ratio
      )
    end

    private

    def text_of(selector)
      @doc.at_css(selector)&.text&.strip&.presence
    end

    def attr_of(selector, attribute)
      @doc.at_css(selector)&.[](attribute)&.strip&.presence
    end

    def headings
      @doc.css('h1, h2, h3').first(MAX_ITEMS).filter_map do |h|
        text = h.text.squish
        next if text.blank?

        { level: h.name, text: text.truncate(200) }
      end
    end

    def paragraphs
      budget = MAX_TEXT_CHARS
      @doc.css('p, li').filter_map do |p|
        break if budget <= 0

        text = p.text.squish
        next if text.length < 25 # nav crumbs and labels, not prose

        budget -= text.length
        text.truncate(500)
      end.first(MAX_ITEMS)
    end

    def images
      @doc.css('img').first(MAX_ITEMS).filter_map do |img|
        src = img['src'] || img['data-src']
        next if src.blank? || src.start_with?('data:')

        {
          src: absolutize(src),
          alt: img['alt'].to_s.squish.presence,
          klass: img['class'].to_s.squish.presence
        }.compact
      end
    end

    def links
      @doc.css('a[href]').first(200).filter_map do |a|
        href = a['href'].to_s.strip
        next if href.blank? || href.start_with?('#', 'javascript:')

        label = a.text.squish
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

    attr_reader :iframes, :scripts

    def raw_iframes
      @doc.css('iframe[src]').first(20).map { |f| f['src'] }.compact
    end

    def raw_scripts
      external = @doc.css('script[src]').map { |s| s['src'] }.compact
      # Inline scripts matter for vendor detection (many widgets are inline
      # bootstraps), but only their first line or so carries the signature.
      inline = @doc.css('script:not([src])').first(20).filter_map do |s|
        body = s.text.to_s.squish
        body.presence&.truncate(300)
      end
      { external: external.first(60), inline: inline }
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
