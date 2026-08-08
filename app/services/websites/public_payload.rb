# frozen_string_literal: true

module Websites
  # The JSON a browser needs to render a tenant website.
  #
  # Extracted from Api::V1::WebsitesController#by_slug_public so the server-rendered page and
  # the preview endpoint produce identical data. Two serialisations of the same thing would
  # drift, and the symptom would be a dealer's live site differing from their preview in
  # ways nobody could reproduce.
  #
  # Embedded in the page rather than fetched, so a visitor's first paint does not wait on a
  # second round trip, and so a crawler that does execute JavaScript sees the content
  # immediately.
  class PublicPayload
    def self.for(website)
      new(website).to_h
    end

    def initialize(website)
      @website = website
    end

    def to_h
      payload = @website.as_json(
        include: {
          website_pages: {
            only: %i[id title slug path is_visible order blocks show_in_nav show_in_footer page_order],
            methods: [:full_path]
          }
        },
        methods: [:full_theme]
      )

      payload['blog_posts'] = blog_posts
      payload['blog_categories'] = blog_categories
      payload['inventory_embed_config'] = inventory_embed_config
      payload['concierge_enabled'] = concierge_enabled
      # Was missing here while WebsitesController#by_slug_public included it, so
      # every calculator block rendered in the in-app preview and then silently
      # vanished on the dealer's live domain — CalculatorBlock returns null when
      # settings are absent, so it failed as a blank space rather than an error.
      payload['calculator_settings'] = CalculatorSettings.for(@website.company)
      # The site's default contact form, for blocks that do not name one. A
      # dealer who never opened the block editor otherwise published a site
      # reading "Contact form not available" on its contact page.
      payload['lead_form_id'] = DefaultLeadForm.for(@website.company)&.id
      # Narrows the logo strip to brands this dealer actually carries, rather
      # than advertising their competitors on their own site.
      payload['manufacturers'] = LotManufacturers.for(@website.company)
      payload
    end

    private

    def blog_posts
      @website.blog_posts
              .includes(:author, :blog_categories)
              .where(is_deleted: [false, nil])
              .where(status: :published)
              .where('published_at <= ?', Time.current)
              .order(published_at: :desc)
              .limit(12)
              .as_json(
                only: %i[id title slug excerpt featured_image_url featured_image_alt
                         published_at view_count],
                include: {
                  author: { only: %i[id first_name last_name] },
                  blog_categories: { only: %i[id name slug] }
                },
                methods: [:reading_time]
              )
    rescue StandardError => e
      Rails.logger.warn("[Websites::PublicPayload] blog posts failed for #{@website.id}: #{e.message}")
      []
    end

    def blog_categories
      @website.blog_categories
              .where(is_deleted: [false, nil])
              .order(:order, :name)
              .as_json(only: %i[id name slug], methods: [:posts_count])
    rescue StandardError => e
      Rails.logger.warn("[Websites::PublicPayload] blog categories failed for #{@website.id}: #{e.message}")
      []
    end

    # Whether this dealer bought the concierge. Sent so the widget can render
    # itself without a second request on first paint, and so a dealer who has
    # not bought it gets no widget rather than one that 403s on first message.
    def concierge_enabled
      company = @website.company
      return false if company.nil?

      ModuleAccessService.new(company).module_enabled?('marketing.ai_concierge')
    rescue StandardError
      false
    end

    def inventory_embed_config
      company = @website.company
      return {} if company.nil?

      {
        token: company.public_inventory_token,
        company_id: company.id,
        enabled: company.public_inventory_enabled || false,
        card: InventoryCardSettings.for(company)
      }
    end
  end
end
