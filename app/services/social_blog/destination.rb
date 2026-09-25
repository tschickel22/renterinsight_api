# frozen_string_literal: true

module SocialBlog
  # Where a blog version will live, answered before it is published: the
  # address a slug will have, whether a slug is free, and the categories the
  # site already uses. The compose screen shows the address so it can go in
  # the Facebook post before either is published.
  class Destination
    # @param cross_post [SocialPostCrossPost, nil] reads its own target when set
    # @param target [Settings::Target, nil] otherwise, the company's current one
    def self.for(company:, cross_post: nil, location_id: nil)
      if cross_post&.destination == 'marketing_site'
        site = MarketingSites.find(cross_post.marketing_site_key)
        return site && Marketing.new(site)
      end

      settings = Settings.new(company)
      if cross_post&.website_id.present?
        website = settings.candidate_sites.find_by(id: cross_post.website_id)
        return website && Website.new(website)
      end

      target = settings.resolve_target(location_id: location_id)
      return nil if target.nil?

      target.marketing_site ? Marketing.new(target.marketing_site) : Website.new(target.website)
    end

    class Website
      def initialize(website)
        @website = website
      end

      def url_for(slug)
        root = @website.public_url
        path = Websites::BlogPostUrl.path_for_slug(@website, slug)
        root.present? && path.present? ? "#{root.chomp('/')}#{path}" : nil
      end

      def unique_slug(base, **)
        slug = base
        n = 2
        while @website.blog_posts.exists?(slug: slug)
          slug = "#{base}-#{n}"
          n += 1
        end
        slug
      end

      def categories
        @website.blog_categories.active.order(:order, :name).pluck(:name)
      end
    end

    class Marketing
      def initialize(site)
        @site = site
      end

      def url_for(slug)
        @site.post_url(slug)
      end

      # Slugs are unique per company_id. A row with this slug and this title
      # is the same post (an earlier attempt), so its slug is not "taken".
      def unique_slug(base, title: nil)
        rows = taken_rows(base)
        return base if rows.none? { |r| r['slug'] == base && r['title'] != title }

        taken = rows.map { |r| r['slug'] }
        n = 2
        n += 1 while taken.include?("#{base}-#{n}")
        "#{base}-#{n}"
      end

      def categories
        rows = SupabaseRest.request(@site, :get,
                                    "blog_posts?company_id=eq.#{@site.company_uuid}&select=category&limit=500")
        Array(rows).filter_map { |r| r['category'].to_s.strip.presence }.uniq.sort
      rescue SupabaseRest::Error
        []
      end

      private

      def taken_rows(base)
        Array(SupabaseRest.request(
          @site, :get,
          "blog_posts?company_id=eq.#{@site.company_uuid}&slug=like.#{URI.encode_www_form_component(base)}*&select=slug,title"
        ))
      end
    end
  end
end
