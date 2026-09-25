# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'

module SocialBlog
  # Publishes a pending blog version to one of our marketing sites: inserts
  # the row into that site's Supabase blog_posts, then starts a Netlify
  # rebuild, since the site is static and only shows posts it was built with.
  class MarketingSitePublisher
    class Error < StandardError; end

    def self.call(cross_post)
      new(cross_post).call
    end

    def initialize(cross_post)
      @cross_post = cross_post
      @post       = cross_post.social_post
      @site       = MarketingSites.find(cross_post.marketing_site_key)
    end

    def call
      raise Error, "The marketing site '#{@cross_post.marketing_site_key}' is not configured" unless @site

      row = (@cross_post.external_id.present? && find_row(@cross_post.external_id)) || insert_row
      rebuild_error = trigger_rebuild

      @cross_post.update!(
        status:       'published',
        external_id:  row['id'],
        public_url:   @site.post_url(row['slug']),
        published_at: row['published_at'] || Time.current,
        # Published but not yet on the site: say so rather than hide it.
        error:        rebuild_error && "The post was saved, but the site rebuild did not start: #{rebuild_error}"
      )
      row
    end

    private

    def insert_row
      now = Time.current.iso8601
      rows = request(:post, 'blog_posts', body: {
        company_id:         @site.company_uuid,
        title:              @cross_post.title,
        slug:               unique_slug(@cross_post.slug.presence || @cross_post.title.to_s.parameterize),
        content:            @cross_post.content,
        excerpt:            @cross_post.excerpt.to_s,
        author:             author_name,
        featured_image_url: @cross_post.featured_image_url.presence || Array(@post.image_urls).first,
        tags:               Array(@cross_post.tags),
        status:             'published',
        # The Renter Insight project fills this only on update, not insert.
        published_at:       now,
        meta_title:         @cross_post.seo_title,
        meta_description:   @cross_post.seo_description
      }, prefer: 'return=representation')
      row = Array(rows).first
      raise Error, 'Supabase did not return the new post' unless row

      # Saved straight away so a crash before the rebuild cannot cause a second insert on retry.
      @cross_post.update_columns(external_id: row['id'], updated_at: Time.current)
      row
    end

    def find_row(id)
      Array(request(:get, "blog_posts?id=eq.#{URI.encode_www_form_component(id)}&select=id,slug,published_at")).first
    end

    # Slugs are unique per company_id in blog_posts.
    def unique_slug(base)
      base  = base.presence || "post-#{@post.id}"
      query = "blog_posts?company_id=eq.#{@site.company_uuid}&slug=like.#{URI.encode_www_form_component(base)}*&select=slug"
      taken = Array(request(:get, query)).map { |r| r['slug'] }
      return base unless taken.include?(base)

      n = 2
      n += 1 while taken.include?("#{base}-#{n}")
      "#{base}-#{n}"
    end

    def author_name
      user = @post.created_by_user || @post.approved_by
      name = user && [user.try(:first_name), user.try(:last_name)].compact_blank.join(' ')
      name.presence || @post.company.name
    end

    def trigger_rebuild
      return 'no build hook is configured' if @site.build_hook_url.blank?

      uri = URI(@site.build_hook_url)
      res = Net::HTTP.post(uri, '{}', 'Content-Type' => 'application/json')
      res.is_a?(Net::HTTPSuccess) ? nil : "Netlify answered #{res.code}"
    rescue StandardError => e
      e.message
    end

    def request(method, path, body: nil, prefer: nil)
      uri  = URI("#{@site.supabase_url.chomp('/')}/rest/v1/#{path}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl      = uri.scheme == 'https'
      http.open_timeout = 10
      http.read_timeout = 30

      req = method == :post ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
      req['apikey']        = @site.service_key
      req['Authorization'] = "Bearer #{@site.service_key}"
      req['Content-Type']  = 'application/json'
      req['Prefer']        = prefer if prefer
      req.body = body.to_json if body

      res = http.request(req)
      raise Error, "Supabase error (#{res.code}): #{res.body.to_s.truncate(300)}" unless res.is_a?(Net::HTTPSuccess)

      res.body.present? ? JSON.parse(res.body) : nil
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      raise Error, "Supabase timeout: #{e.message}"
    end
  end
end
