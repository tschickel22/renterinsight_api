# frozen_string_literal: true

module SocialBlog
  # Where a company's social posts go as blog posts, and whether the compose
  # screen turns the blog version on by default.
  #
  # Stored as the company setting 'social_blog':
  #   { "destination" => "website_builder", "website_id" => 12, "default_on" => true }
  #   { "destination" => "marketing_site", "marketing_site_key" => "dealertide", "default_on" => false }
  #
  # website_id is optional. Without it the site is picked from the post's
  # location, or the company's only published site. marketing_site is only
  # for our own companies and only a platform admin can choose it.
  class Settings
    KEY = 'social_blog'

    Target = Struct.new(:destination, :website, :marketing_site, keyword_init: true) do
      def name
        website ? website.name : marketing_site.name
      end

      def website_id = website&.id
      def marketing_site_key = marketing_site&.key
    end

    def initialize(company)
      @company = company
    end

    def to_h
      raw = Setting.get('Company', @company.id, KEY)
      raw = {} unless raw.is_a?(Hash)
      {
        'destination'        => raw['destination'] == 'marketing_site' ? 'marketing_site' : 'website_builder',
        'website_id'         => raw['website_id'].presence&.to_i,
        'marketing_site_key' => raw['marketing_site_key'].presence,
        'default_on'         => raw.key?('default_on') ? ActiveModel::Type::Boolean.new.cast(raw['default_on']) : true,
        # Put "Read the full post: <link>" in the Facebook post.
        'link_from_social'   => raw.key?('link_from_social') ? ActiveModel::Type::Boolean.new.cast(raw['link_from_social']) : true
      }
    end

    def update(website_id:, default_on:, destination: nil, marketing_site_key: nil, link_from_social: nil)
      destination = destination.to_s == 'marketing_site' ? 'marketing_site' : 'website_builder'

      if destination == 'marketing_site'
        raise ArgumentError, 'Choose a marketing site' unless MarketingSites.find(marketing_site_key)
      elsif website_id.present? && !candidate_sites.exists?(id: website_id)
        raise ArgumentError, 'That website does not belong to this company'
      end

      Setting.set('Company', @company.id, KEY, {
        'destination'        => destination,
        'website_id'         => destination == 'website_builder' ? website_id.presence&.to_i : nil,
        'marketing_site_key' => destination == 'marketing_site' ? marketing_site_key : nil,
        'default_on'         => ActiveModel::Type::Boolean.new.cast(default_on) != false,
        'link_from_social'   => link_from_social.nil? ? to_h['link_from_social'] : ActiveModel::Type::Boolean.new.cast(link_from_social) != false
      })
      to_h
    end

    # The company's real sites. Never the hidden landing-page container.
    def candidate_sites
      @company.websites.sites.active
    end

    # Where a post from this location goes, or nil when there is no sensible
    # choice and one has to be picked in settings.
    def resolve_target(location_id: nil)
      cfg = to_h
      if cfg['destination'] == 'marketing_site'
        site = MarketingSites.find(cfg['marketing_site_key'])
        return site && Target.new(destination: 'marketing_site', marketing_site: site)
      end

      website = resolve_website(location_id: location_id)
      website && Target.new(destination: 'website_builder', website: website)
    end

    # A saved choice wins, then a published site at the same location, then
    # the only published site.
    def resolve_website(location_id: nil)
      saved = to_h['website_id']
      if saved
        site = candidate_sites.find_by(id: saved)
        return site if site
      end

      published = candidate_sites.where(status: 'published').to_a
      if location_id.present?
        at_location = published.select { |w| w.location_id == location_id.to_i }
        return at_location.first if at_location.size == 1
      end
      published.size == 1 ? published.first : nil
    end

    # The path of the page that lists the site's blog posts, or nil when the
    # site has none. A post is shown at <this path>/post/<slug>.
    def self.blog_page_path(website)
      Websites::BlogPostUrl.blog_page_path(website)
    end
  end
end
