# frozen_string_literal: true

module Websites
  # Builds the head metadata for a tenant page: title, description, canonical, Open Graph.
  #
  # Deliberately scoped to metadata rather than to rendering the page body. The React
  # SiteRenderer already renders 28 block types, several of them interactive (inventory
  # search, payment calculator, blog list), and a hand-written server-side twin of it would
  # drift from the editor preview the first time either changed. Metadata has no such twin:
  # the SPA cannot set it early enough for a crawler anyway, so this is the half that
  # genuinely belongs on the server.
  class PageMetadata
    DESCRIPTION_LIMIT = 300

    # Block types whose text is worth falling back to for a description, in preference
    # order. A hero subtitle describes a page far better than the first paragraph of a
    # legal disclaimer.
    DESCRIPTION_BLOCKS = %w[hero text cta features].freeze

    def initialize(website:, page:, canonical_host:, vehicle: nil)
      @website = website
      @page = page
      @canonical_host = canonical_host
      @vehicle = vehicle
    end

    def to_h
      {
        title: title,
        description: description,
        canonical_url: canonical_url,
        og_image: og_image,
        # A listing is a product, not a brochure page, and the distinction is
        # what lets a shared link render as a home with a price rather than as
        # the dealership.
        og_type: @vehicle ? 'product' : 'website',
        site_name: site_name,
        favicon_url: @website.favicon_url.presence,
        robots: robots
      }
    end

    private

    def seo_config
      @seo_config ||= (@website.seo_config.presence || {}).deep_stringify_keys
    end

    def brand
      @brand ||= (@website.brand.presence || {}).deep_stringify_keys
    end

    def site_name
      brand['company_name'].presence || @website.name.presence || @canonical_host
    end

    # Page title first, then the site default. The site name is appended rather than
    # replacing the page title, so every page is not identically titled in search results.
    def title
      page_title = home_title.presence || @page&.seo_title.presence || @page&.title.presence
      default = seo_config['title'].presence || site_name

      return default if page_title.blank?
      return page_title if page_title.casecmp?(default.to_s)

      "#{page_title} | #{default}"
    end

    # The home's own words first. A listing that inherits the site description
    # gives every one of a dealer's homes an identical search result.
    def home_title
      return nil if @vehicle.nil?

      [@vehicle.try(:year), @vehicle.try(:make), @vehicle.try(:model)]
        .map { |part| part.to_s.strip.presence }.compact.join(' ').presence
    end

    def home_description
      return nil if @vehicle.nil?

      specs = [
        ("#{@vehicle.bedrooms} bed" if @vehicle.try(:bedrooms).present?),
        ("#{@vehicle.bathrooms} bath" if @vehicle.try(:bathrooms).present?),
        ("#{@vehicle.square_feet} sq ft" if @vehicle.try(:square_feet).present?)
      ].compact

      own = @vehicle.try(:description).to_s.squish.presence
      return own if own.present?
      return nil if specs.empty?

      "#{home_title}, #{specs.join(', ')}. Available now at #{site_name}."
    end

    def description
      (home_description.presence ||
        @page&.seo_description.presence ||
        seo_config['description'].presence ||
        brand['description'].presence ||
        derived_description).to_s.truncate(DESCRIPTION_LIMIT).presence
    end

    # Pulls the first meaningful copy off the page so a dealer who never filled in an SEO
    # description still gets something better than nothing in a search result.
    def derived_description
      blocks = Array(@page&.blocks)
      DESCRIPTION_BLOCKS.each do |type|
        block = blocks.find { |b| b.is_a?(Hash) && b['type'].to_s == type }
        next if block.nil?

        content = block['content']
        next unless content.is_a?(Hash)

        text = content.values_at('subtitle', 'description', 'body', 'text', 'title')
                      .find { |v| v.is_a?(String) && v.strip.length > 20 }
        return strip_markup(text) if text.present?
      end
      nil
    end

    # Content authored in the builder already carries HTML entities, and these values are
    # escaped again on the way into the tag. Without unescaping first, an ampersand ships as
    # "&amp;amp;" and a dealer's description reads "manufactured &amp; modular homes" in
    # search results.
    def strip_markup(text)
      stripped = ActionController::Base.helpers.strip_tags(text.to_s)
      CGI.unescapeHTML(stripped).squish
    end

    def canonical_url
      # A home canonicalises to its own address. Without this every listing would
      # point at whichever page happened to resolve, and they would all
      # deduplicate onto one another in search.
      home_path = HomeUrl.path_for(@vehicle) if @vehicle
      return "https://#{@canonical_host}#{home_path}" if home_path.present?

      path = @page&.path.presence || '/'
      path = "/#{path}" unless path.start_with?('/')
      path = '' if path == '/'

      "https://#{@canonical_host}#{path}"
    end

    def og_image
      # The home itself, so a shared listing previews as that home rather than
      # as the dealer's logo.
      home_image.presence ||
        @page&.og_image_url.presence ||
        seo_config['og_image'].presence ||
        brand['logo_url'].presence
    end

    def home_image
      return nil if @vehicle.nil?

      Array(@vehicle.try(:image_urls)).first
    rescue StandardError
      nil
    end

    # An unpublished site should never have resolved this far, but if anything ever routes
    # one here, tell crawlers not to index it rather than relying on that invariant.
    def robots
      return 'noindex, nofollow' unless @website.status == 'published'
      return 'noindex, nofollow' if seo_config['noindex'].to_s == 'true'

      'index, follow'
    end
  end
end
