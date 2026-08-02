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

    def initialize(website:, page:, canonical_host:)
      @website = website
      @page = page
      @canonical_host = canonical_host
    end

    def to_h
      {
        title: title,
        description: description,
        canonical_url: canonical_url,
        og_image: og_image,
        og_type: 'website',
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
      page_title = @page&.seo_title.presence || @page&.title.presence
      default = seo_config['title'].presence || site_name

      return default if page_title.blank?
      return page_title if page_title.casecmp?(default.to_s)

      "#{page_title} | #{default}"
    end

    def description
      (@page&.seo_description.presence ||
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

    def strip_markup(text)
      ActionController::Base.helpers.strip_tags(text.to_s).squish
    end

    def canonical_url
      path = @page&.path.presence || '/'
      path = "/#{path}" unless path.start_with?('/')
      path = '' if path == '/'

      "https://#{@canonical_host}#{path}"
    end

    def og_image
      @page&.og_image_url.presence ||
        seo_config['og_image'].presence ||
        brand['logo_url'].presence
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
