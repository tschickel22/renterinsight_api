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
    # Below this a search snippet is too short to say anything useful.
    DESCRIPTION_MIN = 70
    # Search results truncate a title around here. Past it the tail is spent
    # rather than shown.
    TITLE_LIMIT = 65

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

      combined = "#{page_title} | #{default}"
      return combined if combined.length <= TITLE_LIMIT

      # Both do not fit, so the site name is what goes. It repeats on every
      # other result from the same domain, while the page title is the only part
      # that says which page this is. Home titles are where this bites: a model
      # name plus a dealership name is routinely over the limit, and truncation
      # was landing mid model number.
      page_title
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
      text = (home_description.presence ||
        @page&.seo_description.presence ||
        seo_config['description'].presence ||
        brand['description'].presence ||
        derived_description).to_s.squish.presence
      return nil if text.blank?

      qualify(text).truncate(DESCRIPTION_LIMIT).presence
    end

    # Under about 70 characters a snippet is too short to say much, and the
    # descriptions that fall short are the derived ones: a hero subtitle is
    # written as a tagline, not as a search result. Naming the dealership and
    # where it is fills the line with the two things a local searcher is
    # actually checking. Both are facts already on the record, so nothing here
    # claims anything on the dealer's behalf.
    def qualify(text)
      return text if text.length >= DESCRIPTION_MIN

      suffix = [site_name, dealership_locality].compact_blank.join(', ')
      return text if suffix.blank? || text.include?(site_name.to_s)

      "#{text.sub(/[.\s]+\z/, '')}. #{suffix}."
    end

    def dealership_locality
      place = @website.location&.address_line1.present? ? @website.location : @website.try(:company)
      return nil if place.nil?

      [place.try(:city).presence, place.try(:state).presence].compact.join(', ').presence
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
        brand['logo_url'].presence ||
        # A dealer who never uploaded a logo was leaving every brochure page with
        # no share preview at all, so their links posted to Facebook and to a
        # text message as bare grey boxes. A home from their own lot is a better
        # preview than a logo anyway.
        first_inventory_image
    end

    # Cheap by construction: a handful of rows, first usable photo wins. Never
    # fatal, because a missing preview image must not take the page down.
    def first_inventory_image
      company = @website.try(:company)
      return nil if company.nil?

      company.vehicles
             .where(is_deleted: [false, nil], status: HomeUrl::SERVABLE_STATUSES)
             .order(updated_at: :desc)
             .limit(20)
             .each do |vehicle|
        url = vehicle.public_image_urls.first
        return url if url.present?
      end
      nil
    rescue StandardError => e
      Rails.logger.warn("[PageMetadata] inventory og:image failed for #{@website&.id}: #{e.message}")
      nil
    end

    def home_image
      return nil if @vehicle.nil?

      @vehicle.public_image_urls.first
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
