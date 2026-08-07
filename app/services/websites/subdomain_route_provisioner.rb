# frozen_string_literal: true

module Websites
  # Binds the host-rewriting Worker to a site's platform subdomain.
  #
  # *.mydealertide.com resolves at Cloudflare, but DNS alone is not enough:
  # Render rejects any Host it does not recognise, so without a Worker route
  # the rewrite never happens and every subdomain answers 403. Measured
  # directly after the wildcard record was added.
  #
  # A single wildcard ROUTE would also have worked and needed no code. It was
  # rejected deliberately: *.mydealertide.com/* also matches
  # origin.mydealertide.com and connect.mydealertide.com, which are the
  # Cloudflare for SaaS fallback origin and CNAME target that every dealer
  # custom domain depends on. Putting the Worker in front of those to save one
  # API call per site is not a trade worth making.
  #
  # So this mirrors what dealer custom domains already do in
  # Api::V1::CompanyDomainsController — one route per hostname, same service,
  # same method. See CloudflareSaasService#create_worker_route.
  #
  # Every method is best effort and returns a boolean rather than raising. A
  # site whose route failed is still a valid site, the failure is recoverable
  # by running the backfill, and a Cloudflare outage must not block saving a
  # website.
  class SubdomainRouteProvisioner
    class << self
      # @return [String, nil] the host a visitor would type, or nil when the
      #   site has no platform subdomain
      def host_for(website)
        subdomain = website&.subdomain.presence
        return nil if subdomain.blank?

        root = Brand.current.site_host_root.to_s.presence
        return nil if root.blank?

        "#{subdomain}.#{root}"
      end

      # Ensure the Worker runs for this site's subdomain.
      def ensure(website)
        host = host_for(website)
        return false if host.blank?

        with_service { |cf| cf.create_worker_route(host) }
      end

      # Drop the route for a host that is no longer in use.
      #
      # Takes a host string rather than a website, because the caller needs
      # this for the PREVIOUS subdomain, which the record no longer holds.
      def remove(host)
        return false if host.blank?

        with_service { |cf| cf.delete_worker_route(host) }
      end

      private

      # Absent configuration is a normal state, not an error: development and
      # test have no Cloudflare credentials, and CLOUDFLARE_WORKER_SCRIPT is
      # deliberately unset before the Worker exists.
      def with_service
        return false unless CloudflareSaasService.configured?

        yield CloudflareSaasService.new
      rescue StandardError => e
        Rails.logger.warn("[Websites::SubdomainRouteProvisioner] #{e.class}: #{e.message}")
        false
      end
    end
  end
end
