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
    # Where prose lives. The contact keys are here because a dealer's address,
    # phone and hours are the highest value text on the site for local search,
    # and they were being dropped: they live on block types that carry no
    # "description".
    TEXT_KEYS = %w[subtitle description body text caption answer content blurb
                   address phone email hours].freeze
    # Rich text authored in the builder's editor. The text block stores its whole
    # body under "html", which no text key matched, so a contact page's hours,
    # phone number and address never reached a crawler at all.
    RICH_TEXT_KEYS = %w[html bodyHtml contentHtml].freeze
    # Structure worth keeping from that editor. Everything else, including the
    # inline grid styling the builder emits, is dropped.
    ALLOWED_TAGS = %w[h2 h3 h4 p ul ol li strong em b i br a blockquote].freeze
    ALLOWED_ATTRS = %w[href].freeze
    # Keys whose value is a list of sub-items worth rendering.
    LIST_KEYS = %w[features items faqs questions steps stats members testimonials
                   cards columns benefits services points].freeze
    # Blocks whose content is interactive and cannot be represented as text.
    # Filtering, sorting and paging are JavaScript by nature.
    #
    # The map used to be here, which threw away the street address with the
    # embed. The embed is worthless to a crawler and the address is the single
    # most valuable line on a dealer's contact page, so the block stays and only
    # its embed URL is ignored.
    SKIP_TYPES = %w[inventorySearch inventory_search calculator video
                    blogList logoShowcase].freeze
    # Rendered as a plain list of the homes actually on the lot. This used to be
    # skipped on the reasoning that the per-home pages in the sitemap were its
    # crawlable form, which left the inventory page itself at 52 words and
    # nothing linking to a home except the sitemap. The list is the same homes a
    # visitor sees, so it stays the opposite of cloaking, and it gives a crawler
    # a path to every listing from the page a buyer actually lands on.
    INVENTORY_TYPES = %w[inventory].freeze

    MAX_ITEMS = 12
    MAX_IMAGES = 8
    # Enough to establish the lot without turning one page into the whole
    # catalogue. The sitemap carries the full list.
    MAX_LISTED_HOMES = 12
    MAX_RELATED_HOMES = 8

    def initialize(website:, page:, canonical_host:, vehicle: nil)
      @website = website
      @page = page
      @canonical_host = canonical_host
      @vehicle = vehicle
    end

    # Takes the crawlable copy out of the visual flow without taking it out of
    # the document.
    #
    # TenantSiteApp removes #dt-prerender when it mounts, so this markup was only
    # ever meant to be on screen for the moment before hydration. On a plain
    # dealer page that moment passed unnoticed. On an imported landing page it
    # does not: the design's styling lives in the block's own stylesheet, which
    # the crawlable copy deliberately strips, so what paints first is several
    # kilobytes of unstyled prose that a visitor reads as the page having broken.
    # Hiding it earns nothing back for the case it exists to serve, because the
    # consumers this feature was built for (assistants, link previews, crawlers
    # that do not execute JavaScript) do not apply CSS at all. Google renders,
    # sees it hidden, and still has the React page, which is the same content in
    # the same words.
    PRERENDER_STYLE = '#dt-prerender{position:absolute;width:1px;height:1px;margin:-1px;' \
                      'padding:0;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap;border:0}'

    # @return [String, nil] HTML for the crawlable container, or nil when there
    #   is nothing to say
    def call
      sections = @vehicle ? home_sections : page_sections
      return nil if sections.blank?

      <<~HTML
        <style>#{PRERENDER_STYLE}</style>
        <div id="dt-prerender">
        #{sections}
        #{dealership_footer}
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
    #
    # A listing with no dealer-written description used to render 33 words, which
    # is under any threshold for a page having a subject. Everything added here
    # is read off the record rather than composed: a spec sheet, a sentence that
    # states those same specs in prose, and links to the rest of the lot. Nothing
    # asserts anything about the home that the dealer did not enter, because
    # inventing "spacious open floor plan" would be putting words in a dealer's
    # mouth about a product a buyer is about to spend six figures on.
    def home_sections
      parts = +''
      parts << "<h1>#{esc(home_title)}</h1>\n"

      summary = home_summary
      parts << "<p>#{esc(summary)}</p>\n" if summary.present?

      specs = home_specs
      parts << "<ul>\n#{specs.map { |s| "<li>#{esc(s)}</li>" }.join("\n")}\n</ul>\n" if specs.any?

      description = @vehicle.try(:description).to_s.squish.presence
      parts << "<p>#{esc(description)}</p>\n" if description

      features = home_features
      if features.any?
        parts << "<h2>Features</h2>\n<ul>\n#{features.map { |f| "<li>#{esc(f)}</li>" }.join("\n")}\n</ul>\n"
      end

      images = safe_images(@vehicle).first(MAX_IMAGES)
      images.each { |url| parts << image_tag(url, home_title) }

      parts << "<p>#{esc(availability_sentence)}</p>\n"
      parts << related_homes
      parts
    end

    def home_title
      [@vehicle.try(:year), @vehicle.try(:make), @vehicle.try(:model)]
        .map { |p| p.to_s.strip.presence }.compact.join(' ').presence || 'Home'
    end

    # The spec sheet restated as a sentence. A crawler and an assistant both read
    # prose more reliably than a list, and this is the same information either
    # way.
    def home_summary
      descriptors = [
        @vehicle.try(:condition).to_s.strip.presence&.downcase,
        section_phrase,
        home_type_phrase
      ].compact

      noun = descriptors.any? ? "#{descriptors.join(' ')} home" : 'home'
      sentence = +"The #{home_title} is a #{noun}"

      rooms = [
        ("#{whole(@vehicle.bedrooms)} bedrooms" if @vehicle.try(:bedrooms).present?),
        ("#{whole(@vehicle.bathrooms)} bathrooms" if @vehicle.try(:bathrooms).present?),
        ("#{number_with_delimiter(@vehicle.square_feet)} square feet of living space" \
          if @vehicle.try(:square_feet).to_i.positive?)
      ].compact

      sentence << " with #{to_sentence(rooms)}" if rooms.any?
      "#{sentence}."
    end

    # "single section", "double section". Reads as the industry does rather than
    # as a column value.
    def section_phrase
      count = @vehicle.try(:sections).to_i
      case count
      when 1 then 'single section'
      when 2 then 'double section'
      when 3 then 'triple section'
      end
    end

    # HUD stays upper case; anything else is a stored key that has to be readable
    # before it goes in front of a buyer.
    def home_type_phrase
      type = @vehicle.try(:home_type).to_s.strip.presence
      return nil if type.blank?

      type.casecmp?('hud') ? 'HUD' : type.tr('_', ' ').downcase
    end

    def home_specs
      [
        ("Year: #{@vehicle.year}" if @vehicle.try(:year).present?),
        ("Manufacturer: #{@vehicle.make}" if @vehicle.try(:make).present?),
        ("Model: #{@vehicle.model}" if @vehicle.try(:model).present?),
        ("Bedrooms: #{whole(@vehicle.bedrooms)}" if @vehicle.try(:bedrooms).present?),
        ("Bathrooms: #{whole(@vehicle.bathrooms)}" if @vehicle.try(:bathrooms).present?),
        ("Square feet: #{number_with_delimiter(@vehicle.square_feet)}" if @vehicle.try(:square_feet).to_i.positive?),
        ("Dimensions: #{@vehicle.length} by #{@vehicle.width} feet" \
          if @vehicle.try(:length).present? && @vehicle.try(:width).present?),
        ("Sections: #{@vehicle.sections}" if @vehicle.try(:sections).to_i.positive?),
        ("Home type: #{home_type_phrase}" if home_type_phrase.present?),
        ("Condition: #{@vehicle.condition.to_s.humanize}" if @vehicle.try(:condition).present?),
        ("Stock number: #{@vehicle.stock_number}" if @vehicle.try(:stock_number).present?),
        ("Community: #{@vehicle.community_name}" if @vehicle.try(:community_name).present?),
        ("Location: #{home_location}" if home_location.present?),
        ("Price: $#{number_with_delimiter(@vehicle.sale_price.to_i)}" if @vehicle.try(:sale_price).to_f.positive?)
      ].compact
    end

    def home_location
      @home_location ||= [@vehicle.try(:location_city), @vehicle.try(:location_state)]
                         .map { |p| p.to_s.strip.presence }.compact.join(', ').presence
    end

    # Dealer-entered lists only. An empty array stays empty rather than becoming
    # a heading with nothing under it.
    def home_features
      raw = [@vehicle.try(:features), @vehicle.try(:appliances)].flat_map { |v| Array(v) }
      raw += @vehicle.try(:special_features).to_s.split(/[,;\n]/) if @vehicle.try(:special_features).present?

      raw.filter_map do |item|
        value = item.is_a?(Hash) ? item.values_at('name', 'label', 'title').compact.first : item
        next unless value.is_a?(String)

        value.squish.presence
      end.uniq.first(MAX_ITEMS)
    end

    def availability_sentence
      where = home_location.present? ? " in #{home_location}" : ''
      status = @vehicle.try(:status).to_s == 'available_to_order' ? 'available to order' : 'available'

      "This home is #{status} from #{site_name}#{where}. Contact the dealership for pricing, " \
        'delivery and setup details.'
    end

    # Other homes on the same lot, linked. Gives a crawler a route between
    # listings, which it previously only had through the sitemap, and gives a
    # buyer landing from search somewhere to go next.
    def related_homes
      homes = listable_homes.reject { |v| v.id == @vehicle.id }.first(MAX_RELATED_HOMES)
      return '' if homes.empty?

      "<h2>#{esc("More homes at #{site_name}")}</h2>\n#{home_link_list(homes)}"
    end

    def inventory_list
      homes = listable_homes.first(MAX_LISTED_HOMES)
      return '' if homes.empty?

      home_link_list(homes)
    end

    def home_link_list(homes)
      items = homes.filter_map do |vehicle|
        path = HomeUrl.path_for(vehicle)
        next if path.blank?

        label = [vehicle.try(:year), vehicle.try(:make), vehicle.try(:model)]
                .map { |p| p.to_s.strip.presence }.compact.join(' ').presence || 'Home'

        %(<li><a href="#{esc(path)}">#{esc(label)}</a>#{home_link_specs(vehicle)}</li>)
      end
      return '' if items.empty?

      "<ul>\n#{items.join("\n")}\n</ul>\n"
    end

    def home_link_specs(vehicle)
      specs = [
        ("#{whole(vehicle.bedrooms)} bed" if vehicle.try(:bedrooms).present?),
        ("#{whole(vehicle.bathrooms)} bath" if vehicle.try(:bathrooms).present?),
        ("#{number_with_delimiter(vehicle.square_feet)} sq ft" if vehicle.try(:square_feet).to_i.positive?)
      ].compact
      return '' if specs.empty?

      " <span>#{esc(specs.join(', '))}</span>"
    end

    # Loaded once per request. Same scope as the sitemap and the public inventory
    # endpoint, so a link here can never resolve to a home the site would refuse
    # to serve.
    def listable_homes
      @listable_homes ||= begin
        company = @website.try(:company)
        if company.nil?
          []
        else
          company.vehicles
                 .where(is_deleted: [false, nil], status: HomeUrl::SERVABLE_STATUSES)
                 .order(updated_at: :desc)
                 .limit(MAX_LISTED_HOMES + MAX_RELATED_HOMES)
                 .to_a
        end
      end
    rescue StandardError => e
      Rails.logger.warn("[BodyRenderer] homes failed for #{@website&.id}: #{e.message}")
      @listable_homes = []
    end

    # 3.0 bathrooms reads as a database column. 3 bathrooms reads as a house.
    def whole(value)
      number = value.to_f
      (number % 1).zero? ? number.to_i.to_s : format('%g', number)
    end

    def number_with_delimiter(value)
      ActiveSupport::NumberHelper.number_to_delimited(value.to_i)
    end

    def to_sentence(parts)
      parts.to_sentence(two_words_connector: ' and ', last_word_connector: ' and ')
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
        type = block['type'].to_s
        next if SKIP_TYPES.include?(type)

        content = block['content'].is_a?(Hash) ? block['content'] : block
        title = first_value(content, TITLE_KEYS)

        if INVENTORY_TYPES.include?(type)
          listing = inventory_list
          next if listing.blank?

          parts << (heading_used ? "<h2>#{esc(title.presence || 'Homes for sale')}</h2>\n"
                                 : "<h1>#{esc(title.presence || 'Homes for sale')}</h1>\n")
          heading_used = true
          parts << listing
          next
        end

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

        RICH_TEXT_KEYS.each do |key|
          value = content[key]
          next unless value.is_a?(String) && value.strip.present?

          safe = sanitize_rich_text(value)
          parts << "#{safe}\n" if safe.present?
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

    # The dealership's name, address and phone on every page, the way a real
    # site's footer carries them.
    #
    # Two reasons beyond word count. Local search ranks on seeing a consistent
    # name, address and phone, and ours appeared only inside JSON-LD. Structured
    # data is also supposed to describe what a visitor can see, so a store node
    # asserting a street address that appears nowhere in the page is the weaker
    # kind of markup. Same source as the JSON-LD, so the two cannot disagree.
    def dealership_footer
      target = place
      return '' if target.nil?

      street = target.try(:address_line1).presence
      return '' if street.blank?

      locality = [target.try(:city).presence, target.try(:state).presence].compact.join(', ')
      postal = target.try(:zip).presence || target.try(:postal_code).presence || target.try(:zip_code).presence
      phone = target.try(:phone).presence || @website.company.try(:phone).presence

      lines = [
        street,
        [locality.presence, postal].compact.join(' ').presence,
        (phone.present? ? "Phone: #{phone}" : nil)
      ].compact

      "<address><strong>#{esc(site_name)}</strong>\n" \
        "#{lines.map { |line| "<span>#{esc(line)}</span>" }.join("\n")}\n</address>\n"
    rescue StandardError => e
      Rails.logger.warn("[BodyRenderer] footer failed for #{@website&.id}: #{e.message}")
      ''
    end

    # Mirrors Websites::StructuredData: the lot the site belongs to when it has a
    # street, otherwise the company. Falls back on the street specifically rather
    # than on a location existing, because locations are routinely created with a
    # name and nothing else.
    def place
      @place ||= if @website.location&.address_line1.presence
                   @website.location
                 else
                   @website.company
                 end
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

    # Keeps the headings and lists a dealer wrote, drops everything else. An h1
    # inside authored copy is demoted rather than removed, because two h1 tags on
    # a page is exactly what our own audit fails a site for.
    # Elements whose text is not prose. Removed whole, children included.
    #
    # Rails' sanitize drops a disallowed TAG and keeps what was inside it, which
    # is right for a <div> and badly wrong for a <style>: an imported design
    # stores its stylesheet under the same "html" key its copy lives under, so
    # the crawlable body filled with ":host { --navy-950:#071528; ... }" and a
    # visitor watched a page of CSS render before React replaced it. That is a
    # flash of the wrong thing on every load, and it puts a stylesheet in front
    # of a crawler as though it were the page's words.
    NON_PROSE_ELEMENTS = %w[style script noscript template svg].freeze

    def sanitize_rich_text(html)
      doc = Nokogiri::HTML::DocumentFragment.parse(html)
      doc.css(NON_PROSE_ELEMENTS.join(',')).each(&:remove)

      demoted = doc.to_html.gsub(%r{<(/?)h1(\s|>)}i, '<\1h2\2')

      ActionController::Base.helpers.sanitize(
        demoted, tags: ALLOWED_TAGS, attributes: ALLOWED_ATTRS
      ).to_s.strip.presence
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
