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
      service.revalidate_custom_hostname(id)
      parsed = service.parse_custom_hostname_response(service.check_custom_hostname_status(id))

      @domain.update!(
        verification_status: parsed[:verification_status],
        ssl_status: parsed[:ssl_status],
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

    def id
      @domain.cloudflare_custom_hostname_id
    end

    def service
      @service ||= CloudflareSaasService.new
    end
  end
end
