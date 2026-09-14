# frozen_string_literal: true

module LandingPages
  # The address a visitor types to reach a landing page, or nil when its site
  # has no host yet.
  #
  # Built from the same resolution order Websites::HostResolver uses, so what
  # the builder shows is what a visitor would actually type. Shared by the
  # landing page builder and the starter plays that create pages.
  module PublicUrl
    def self.for(page)
      site = page&.website
      return nil if site.nil?

      host = site.company_domains.detect(&:web_enabled?)&.hostname
      host ||= site.domain.presence
      # site_host_root, not subdomain_root: the platform domain has no wildcard
      # record, so a URL built on it named a host that does not resolve and the
      # View button opened a browser error page.
      host ||= Websites::SiteAddress.host_for(site) if site.subdomain.present?
      return nil if host.blank?

      "https://#{host}#{page.path}"
    end
  end
end
