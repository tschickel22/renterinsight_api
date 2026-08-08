# frozen_string_literal: true

module Websites
  # A crawlable HTML copy of a page, rendered server side.
  #
  # The head has been correct for a while, but the body a crawler received was
  # 1.3KB containing a script and an empty <div id="root">. Every heading,
  # paragraph and listing existed only after React ran. Google executes
  # JavaScript so it largely coped; the assistants buyers increasingly ask
  # (ChatGPT, Perplexity, Claude) frequently do not, and neither does a link
  # preview. Measured against a Trove-built site serving 618KB of rendered body,
  # this was the one dimension where the category leader beat us outright.
  #
  # Not a React renderer. It walks the same blocks the client renders and emits
  # semantic HTML: one h1, an h2 per section, paragraphs, images with alt text,
  # and real links between pages so a crawler can walk the site without running
  # the grid. The words are identical to what a visitor sees, which is what keeps
  # this the opposite of cloaking.
  #
  # Generated per request rather than stored. A stored copy needs invalidating on
  # every block edit, and a prerendered page that disagrees with the live one is
  # worse than none. Blocks are already loaded to build the payload.
  #
  # Deliberately generic: it reads whatever text-shaped keys a block carries
  # rather than switching on the 16 block types in use. A block type added later
  # degrades to "renders its title and text" instead of vanishing.
  class BodyRenderer
    # Where a heading lives, in preference order.
    TITLE_KEYS = %w[title heading headline name].freeze
    # Where prose lives.
    TEXT_KEYS = %w[subtitle description body text caption answer content blurb].freeze
    # Keys whose value is a list of sub-items worth rendering.
    LIST_KEYS = %w[features items faqs questions steps stats members testimonials
                   cards columns benefits services points].freeze
    # Blocks whose content is interactive and cannot be represented as text. The
    # inventory grid is JavaScript by nature; its crawlable form is the per-home
    # pages in the sitemap, not a fake grid here.
    SKIP_TYPES = %w[inventory inventorySearch inventory_search calculator map video
                    blogList logoShowcase].freeze

    MAX_ITEMS = 12
    MAX_IMAGES = 8

    def initialize(website:, page:, canonical_host:, vehicle: nil)
      @website = website
      @page = page
      @canonical_host = canonical_host
      @vehicle = vehicle
    end

    # @return [String, nil] HTML for the crawlable container, or nil when there
    #   is nothing to say
    def call
      sections = @vehicle ? home_sections : page_sections
      return nil if sections.blank?

      <<~HTML
        <div id="dt-prerender">
        #{sections}
        #{site_nav}
        </div>
      HTML
    end

    private

    def esc(value)
      ERB::Util.html_escape(value.to_s.squish)
    end

    def brand
      @brand ||= (@website.brand.presence || {}).deep_stringify_keys
    end

    def site_name
      brand['company_name'].presence || @website.name.presence || @canonical_host
    end

    # A single home reads as the product page it is.
    def home_sections
      parts = +''
      parts << "<h1>#{esc(home_title)}</h1>\n"

      specs = home_specs
      parts << "<ul>\n#{specs.map { |s| "<li>#{esc(s)}</li>" }.join("\n")}\n</ul>\n" if specs.any?

      description = @vehicle.try(:description).to_s.squish.presence
      parts << "<p>#{esc(description)}</p>\n" if description

      images = safe_images(@vehicle).first(MAX_IMAGES)
      images.each { |url| parts << image_tag(url, home_title) }

      parts << "<p>#{esc("Available at #{site_name}.")}</p>\n"
      parts
    end

    def home_title
      [@vehicle.try(:year), @vehicle.try(:make), @vehicle.try(:model)]
        .map { |p| p.to_s.strip.presence }.compact.join(' ').presence || 'Home'
    end

    def home_specs
      [
        ("#{@vehicle.bedrooms} bedrooms" if @vehicle.try(:bedrooms).present?),
        ("#{@vehicle.bathrooms} bathrooms" if @vehicle.try(:bathrooms).present?),
        ("#{@vehicle.square_feet} square feet" if @vehicle.try(:square_feet).present?),
        ("Price: $#{@vehicle.sale_price.to_i}" if @vehicle.try(:sale_price).to_f.positive?)
      ].compact
    end

    def safe_images(vehicle)
      vehicle.public_image_urls
    rescue StandardError
      []
    end

    def page_sections
      blocks = Array(@page&.blocks).select { |b| b.is_a?(Hash) }
      return nil if blocks.empty?

      parts = +''
      heading_used = false

      blocks.sort_by { |b| b['order'].to_i }.each do |block|
        next if SKIP_TYPES.include?(block['type'].to_s)

        content = block['content'].is_a?(Hash) ? block['content'] : block
        title = first_value(content, TITLE_KEYS)

        if title.present?
          # Exactly one h1 per page. Every later heading steps down, which is
          # both correct document structure and what our own audit checks.
          parts << (heading_used ? "<h2>#{esc(title)}</h2>\n" : "<h1>#{esc(title)}</h1>\n")
          heading_used = true
        end

        TEXT_KEYS.each do |key|
          value = content[key]
          parts << "<p>#{esc(value)}</p>\n" if value.is_a?(String) && value.strip.present?
        end

        parts << render_items(content)
        parts << render_images(content, title)
      end

      # A page whose blocks are all interactive still needs a heading, or our own
      # audit would flag the site we just built.
      parts = "<h1>#{esc(@page.title.presence || site_name)}</h1>\n#{parts}" unless heading_used

      parts
    end

    def render_items(content)
      LIST_KEYS.each do |key|
        items = content[key]
        next unless items.is_a?(Array)

        rendered = items.first(MAX_ITEMS).filter_map do |item|
          next unless item.is_a?(Hash)

          heading = first_value(item, TITLE_KEYS)
          text = first_value(item, TEXT_KEYS)
          next if heading.blank? && text.blank?

          +'<li>' \
            "#{heading.present? ? "<h3>#{esc(heading)}</h3>" : ''}" \
            "#{text.present? ? "<p>#{esc(text)}</p>" : ''}" \
            '</li>'
        end

        return "<ul>\n#{rendered.join("\n")}\n</ul>\n" if rendered.any?
      end

      ''
    end

    # Alt text is the accessibility requirement most likely to appear in a
    # complaint, and the thing image search reads. It falls back to the section
    # heading rather than being left empty.
    def render_images(content, title)
      urls = %w[image imageUrl backgroundImage].filter_map { |k| content[k] if content[k].is_a?(String) }
      urls += Array(content['backgroundImages']).select { |u| u.is_a?(String) }
      urls += Array(content['images']).map { |i| i.is_a?(Hash) ? i['url'] : i }.select { |u| u.is_a?(String) }

      urls.uniq.first(MAX_IMAGES).map { |url| image_tag(url, title) }.join
    end

    def image_tag(url, alt)
      return '' if url.blank?

      %(<img src="#{esc(url)}" alt="#{esc(alt.presence || site_name)}" loading="lazy">\n)
    end

    # Real links, so a crawler can reach every page without executing the nav.
    def site_nav
      pages = @website.website_pages.where(is_deleted: [false, nil]).order(:order).limit(50)
      links = pages.filter_map do |page|
        path = page.path.to_s
        next if path.blank?

        href = path.start_with?('/') ? path : "/#{path}"
        %(<li><a href="#{esc(href)}">#{esc(page.title.presence || href)}</a></li>)
      end
      return '' if links.empty?

      "<nav><ul>\n#{links.join("\n")}\n</ul></nav>\n"
    rescue StandardError
      ''
    end

    def first_value(hash, keys)
      keys.each do |key|
        value = hash[key]
        return value.strip if value.is_a?(String) && value.strip.present?
      end
      nil
    end
  end
end
