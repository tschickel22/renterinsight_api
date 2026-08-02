# frozen_string_literal: true

module Websites
  # Resolves an inbound Host header to the tenant website that should answer it.
  #
  # This is the piece every custom-domain approach needs, whoever ends up rendering the
  # HTML. Cloudflare for SaaS forwards the visitor's original Host, so the hostname is the
  # only thing identifying which dealer's site was asked for.
  #
  # Resolution order, most specific first:
  #   1. a verified CompanyDomain linked to a website  (dealer's own domain)
  #   2. websites.domain                               (legacy direct assignment)
  #   3. <subdomain>.<platform root>                   (websites.subdomain)
  #
  # Only published sites resolve. A draft site answering on a live domain would put
  # half-finished content in front of a dealer's customers and, worse, in front of a
  # crawler that then caches it.
  class HostResolver
    Result = Struct.new(:website, :company_domain, :canonical_host, keyword_init: true)

    def self.call(host)
      new(host).call
    end

    def initialize(host)
      @host = normalize(host)
    end

    def call
      return nil if @host.blank?

      from_company_domain || from_website_domain || from_subdomain
    end

    private

    # Strips the port and lowercases. Deliberately does NOT strip "www.": a tenant may
    # register either "dealer.com" or "www.dealer.com" as their hostname, so both spellings
    # are tried as candidates instead of assuming one canonical form.
    def normalize(host)
      host.to_s.downcase.strip.split(':').first.to_s
    end

    # Exact host first, then the other www spelling. Matching the bare domain first would
    # resolve www.dealer.com to a record registered as dealer.com even when the tenant
    # registered both and meant them to differ.
    def host_candidates
      @host_candidates ||= begin
        alt = @host.start_with?('www.') ? @host.delete_prefix('www.') : "www.#{@host}"
        [@host, alt].uniq
      end
    end

    def from_company_domain
      domain = CompanyDomain.where(hostname: host_candidates)
                            .sort_by { |d| host_candidates.index(d.hostname) }
                            .first
      return nil if domain.nil?
      return nil if domain.website_id.blank?

      website = published_scope.find_by(id: domain.website_id, company_id: domain.company_id)
      return nil if website.nil?

      Result.new(website: website, company_domain: domain, canonical_host: domain.hostname)
    end

    def from_website_domain
      website = published_scope.where.not(domain: [nil, '']).where(domain: host_candidates).first
      return nil if website.nil?

      Result.new(website: website, canonical_host: website.domain)
    end

    def from_subdomain
      root = Brand.current.subdomain_root.to_s.downcase
      return nil if root.blank?
      return nil unless @host.end_with?(".#{root}")

      label = @host.delete_suffix(".#{root}")
      return nil if label.blank?

      website = published_scope.find_by(subdomain: label)
      return nil if website.nil?

      Result.new(website: website, canonical_host: @host)
    end

    def published_scope
      Website.where(is_deleted: [false, nil], status: 'published')
    end
  end
end
