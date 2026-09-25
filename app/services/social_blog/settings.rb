# frozen_string_literal: true

module SocialBlog
  # Where a company's social posts go as blog posts, and whether the compose
  # screen ticks "Also publish as a blog post" by default.
  #
  # Stored as the company setting 'social_blog':
  #   { "website_id" => 12, "default_on" => true }
  #
  # website_id is optional. Without it the site is picked from the post's
  # location, or the company's only published site.
  class Settings
    KEY = 'social_blog'

    def initialize(company)
      @company = company
    end

    def to_h
      raw = Setting.get('Company', @company.id, KEY)
      raw = {} unless raw.is_a?(Hash)
      {
        'website_id' => raw['website_id'].presence&.to_i,
        'default_on' => raw.key?('default_on') ? ActiveModel::Type::Boolean.new.cast(raw['default_on']) : true
      }
    end

    def update(website_id:, default_on:)
      if website_id.present? && !candidate_sites.exists?(id: website_id)
        raise ArgumentError, 'That website does not belong to this company'
      end

      Setting.set('Company', @company.id, KEY, {
        'website_id' => website_id.presence&.to_i,
        'default_on' => ActiveModel::Type::Boolean.new.cast(default_on) != false
      })
      to_h
    end

    # The company's real sites. Never the hidden landing-page container.
    def candidate_sites
      @company.websites.sites.active
    end

    # The site a post from this location would go to, or nil when there is no
    # sensible choice. A saved choice wins, then a published site at the same
    # location, then the only published site.
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
      page = website.website_pages.where(is_deleted: [false, nil]).order(:order).detect do |p|
        Array(p.blocks).any? { |b| b.is_a?(Hash) && b['type'] == 'blogList' }
      end
      page&.path
    end
  end
end
