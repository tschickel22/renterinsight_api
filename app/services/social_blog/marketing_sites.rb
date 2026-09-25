# frozen_string_literal: true

module SocialBlog
  # Our own marketing sites (one per brand), which blog versions of the
  # platform's social posts can publish to.
  #
  # Each is a static Astro site on Netlify that reads its blog from Supabase,
  # so publishing is two steps: insert the row, then start a rebuild.
  #
  # Configured entirely in ENV, so no brand name or secret is in code:
  #   MARKETING_BLOG_SITES=renterinsight,dealertide
  #   MARKETING_BLOG_<KEY>_NAME              shown in the app ("DealerTide website")
  #   MARKETING_BLOG_<KEY>_SITE_URL          https://dealertide.com
  #   MARKETING_BLOG_<KEY>_SUPABASE_URL      https://<ref>.supabase.co
  #   MARKETING_BLOG_<KEY>_SUPABASE_SERVICE_KEY  service_role key (bypasses RLS)
  #   MARKETING_BLOG_<KEY>_COMPANY_UUID      the site's PUBLIC_COMPANY_ID
  #   MARKETING_BLOG_<KEY>_BUILD_HOOK_URL    Netlify build hook
  #
  # Only platform admins can point a company at one of these. A client's
  # posts must never land on our site.
  class MarketingSites
    Site = Struct.new(:key, :name, :site_url, :supabase_url, :service_key, :company_uuid, :build_hook_url,
                      keyword_init: true) do
      def complete?
        [supabase_url, service_key, company_uuid].all?(&:present?)
      end

      # With the trailing slash the site serves and canonicalises to, so a
      # link does not start with a redirect.
      def post_url(slug)
        site_url.present? ? "#{site_url.chomp('/')}/blog/#{slug}/" : nil
      end
    end

    FIELDS = %w[NAME SITE_URL SUPABASE_URL SUPABASE_SERVICE_KEY COMPANY_UUID BUILD_HOOK_URL].freeze

    def self.all(env = ENV)
      env.fetch('MARKETING_BLOG_SITES', '').split(',').map(&:strip).reject(&:blank?).filter_map do |key|
        site = build(key, env)
        site if site.complete?
      end
    end

    def self.find(key, env = ENV)
      all(env).detect { |s| s.key == key.to_s }
    end

    def self.build(key, env)
      prefix = "MARKETING_BLOG_#{key.upcase}_"
      Site.new(
        key:            key,
        name:           env["#{prefix}NAME"].presence || key.titleize,
        site_url:       env["#{prefix}SITE_URL"].presence,
        supabase_url:   env["#{prefix}SUPABASE_URL"].presence,
        service_key:    env["#{prefix}SUPABASE_SERVICE_KEY"].presence,
        company_uuid:   env["#{prefix}COMPANY_UUID"].presence,
        build_hook_url: env["#{prefix}BUILD_HOOK_URL"].presence
      )
    end
  end
end
