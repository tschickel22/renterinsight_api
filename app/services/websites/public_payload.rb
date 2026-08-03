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

    def inventory_embed_config
      company = @website.company
      return {} if company.nil?

      {
        token: company.public_inventory_token,
        company_id: company.id,
        enabled: company.public_inventory_enabled || false
      }
    end
  end
end
