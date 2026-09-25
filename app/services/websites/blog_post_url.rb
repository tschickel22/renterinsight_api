# frozen_string_literal: true

module Websites
  # The public address of one blog post on a dealer site.
  #
  # Posts have no website_pages row. The page holding the blogList block lists
  # them, and the React app shows one at <that page's path>/post/<slug>, so
  # that is the address to put in a sitemap, a canonical tag and a Facebook post.
  module BlogPostUrl
    SEGMENT = 'post'

    module_function

    # The path of the page that lists the site's posts, with a leading slash,
    # or nil when the site has no such page.
    def blog_page_path(website)
      page = website.website_pages.where(is_deleted: [false, nil]).order(:order).detect do |p|
        Array(p.blocks).any? { |b| b.is_a?(Hash) && b['type'] == 'blogList' }
      end
      return nil if page.nil? || page.path.blank?

      path = page.path.start_with?('/') ? page.path : "/#{page.path}"
      path.length > 1 ? path.chomp('/') : path
    end

    def path_for(website, blog_post, base: blog_page_path(website))
      path_for_slug(website, blog_post&.slug, base: base)
    end

    # Before the post exists: the address it will have.
    def path_for_slug(website, slug, base: blog_page_path(website))
      return nil if base.blank? || slug.blank?

      "#{base == '/' ? '' : base}/#{SEGMENT}/#{slug}"
    end

    # The slug a request path names, or nil when the path is not a post under
    # this site's blog page.
    def slug_from(website, path, base: blog_page_path(website))
      return nil if base.blank?

      prefix = "#{base == '/' ? '' : base}/#{SEGMENT}/"
      return nil unless path.to_s.start_with?(prefix)

      slug = path.delete_prefix(prefix)
      slug.present? && !slug.include?('/') ? slug : nil
    end
  end
end
