# frozen_string_literal: true

module SocialBlog
  # Turns a pending blog version into a published BlogPost on the company's
  # website-builder site.
  #
  # Created straight as published. A scheduled BlogPost never goes live,
  # because nothing moves it to published, and the social post has already
  # gone out by the time this runs.
  class WebsiteBuilderPublisher
    class Error < StandardError; end

    def self.call(cross_post)
      new(cross_post).call
    end

    def initialize(cross_post)
      @cross_post = cross_post
      @post       = cross_post.social_post
      @company    = cross_post.company
    end

    def call
      # A retry after a crash between creating the post and saving the link
      # would otherwise make a second copy.
      existing = @cross_post.external_id.present? && BlogPost.find_by(id: @cross_post.external_id)
      return finish(existing) if existing

      website = resolve_website
      author  = resolve_author
      raise Error, 'No one to name as the author of the blog post' unless author

      blog_post = website.blog_posts.create!(
        author:             author,
        author_name:        @cross_post.author_name.presence,
        title:              @cross_post.title,
        slug:               unique_slug(website, @cross_post.slug.presence || @cross_post.title.to_s.parameterize),
        excerpt:            @cross_post.excerpt.presence,
        content:            @cross_post.content,
        featured_image_url: @cross_post.featured_image_url.presence || Array(@post.image_urls).first,
        featured_image_alt: @cross_post.title,
        seo_title:          @cross_post.seo_title.presence,
        seo_description:    @cross_post.seo_description.presence,
        status:             :published,
        published_at:       Time.current
      )
      @cross_post.update!(website_id: website.id)
      finish(blog_post)
    end

    private

    def finish(blog_post)
      website = blog_post.website
      @cross_post.update!(
        status:       'published',
        external_id:  blog_post.id.to_s,
        public_url:   public_url(website, blog_post),
        published_at: blog_post.published_at || Time.current,
        error:        nil
      )
      blog_post
    end

    def resolve_website
      settings = Settings.new(@company)
      site = @cross_post.website_id.present? && settings.candidate_sites.find_by(id: @cross_post.website_id)
      site ||= settings.resolve_website(location_id: @post.location_id)
      raise Error, 'No website to publish the blog post to. Choose one in Social Media settings.' unless site

      site
    end

    # author_id is required. Posts made by the scheduler have no creator, so
    # fall back to whoever approved it, then a company admin.
    def resolve_author
      @post.created_by_user || @post.approved_by ||
        User.active.where(company_id: @company.id, role: %w[admin company_admin]).order(:id).first ||
        User.active.where(company_id: @company.id).order(:id).first
    end

    # Slugs are unique per website, and a clash made create! fail outright.
    def unique_slug(website, base)
      base = base.presence || "post-#{@post.id}"
      slug = base
      n = 2
      while website.blog_posts.exists?(slug: slug)
        slug = "#{base}-#{n}"
        n += 1
      end
      slug
    end

    def public_url(website, blog_post)
      root = website.public_url
      path = Websites::BlogPostUrl.path_for(website, blog_post)
      return nil if root.blank? || path.blank?

      "#{root.chomp('/')}#{path}"
    end
  end
end
