# frozen_string_literal: true

module Websites
  # Pulls a custom hostname's current state from Cloudflare and writes it to the domain.
  #
  # Extracted so the Verify button and the background poller share one implementation.
  # Before this, status only changed when someone happened to press Verify, so a dealer's
  # certificate could go active at Cloudflare while the screen said pending indefinitely
  # and nothing would ever correct it.
  class CloudflareStatusRefresher
    Result = Struct.new(:updated, :verified, :ssl_active, :error, keyword_init: true) do
      def ready? = verified && ssl_active
    end

    def self.call(domain, service: nil)
      new(domain, service: service).call
    end

    def initialize(domain, service: nil)
      @domain = domain
      @service = service
    end

    def call
      return Result.new(updated: false, error: 'Domain is not registered with Cloudflare') if id.blank?

      # Reading alone triggers nothing on Cloudflare's side, so a tenant who just published
      # a record would otherwise wait on Cloudflare's own schedule with no way to ask again.
      service.revalidate_custom_hostname(id, ssl_method: ('http' if switch_to_http?))
      parsed = service.parse_custom_hostname_response(service.check_custom_hostname_status(id))

      @domain.update!(
        verification_status: parsed[:verification_status],
        ssl_status: parsed[:ssl_status],
        # Cloudflare reissues certificate tokens when it retries, so the stored set is
        # replaced each time rather than kept. Ownership records stay as created.
        verification_records: @domain.ownership_records + parsed[:certificate_records].to_a,
        ssl_issued_at: parsed[:ssl_status] == 'active' ? (@domain.ssl_issued_at || Time.current) : @domain.ssl_issued_at,
        dns_checked_at: Time.current,
        dns_error: nil
      )

      @domain.activate! if @domain.verified? && @domain.ssl_active? && !@domain.active?

      Result.new(updated: true, verified: @domain.verified?, ssl_active: @domain.ssl_active?)
    rescue CloudflareSaasService::CloudflareError => e
      @domain.update(dns_error: e.message, dns_checked_at: Time.current)
      Result.new(updated: false, error: e.message)
    end

    private

    # TXT validation is chosen when a domain is added while the dealer's old site still
    # answers on it, so the certificate can issue before anyone is moved. Once the CNAME
    # points at us that reason is gone, and HTTP validation passes with no records at all.
    # Staying on TXT left www.cbhms.com without a certificate (2026-11-13) because nobody
    # had published the two challenge records: the site was pointed at us and unreachable.
    #
    # Only once the CNAME really points here, read from the zone's own name server. Moving
    # a hostname to HTTP before that is the www.easyhomesource.com bug: it can never pass.
    def switch_to_http?
      return false if @domain.ssl_active?
      return false if @domain.certificate_records.blank?

      target = @domain.cname_target.to_s.chomp('.')
      return false if target.blank?

      Dns::Lookup.cname(@domain.hostname, zone: @domain.domain_root)
                 .any? { |value| value.to_s.chomp('.').casecmp?(target) }
    rescue StandardError => e
      Rails.logger.warn("[CloudflareStatusRefresher] CNAME check failed for #{@domain.hostname}: #{e.message}")
      false
    end

    def id
      @domain.cloudflare_custom_hostname_id
    end

    def service
      @service ||= CloudflareSaasService.new
    end
  end
end
