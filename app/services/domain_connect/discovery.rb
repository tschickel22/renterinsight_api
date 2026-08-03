# frozen_string_literal: true

require 'resolv'
require 'net/http'

module DomainConnect
  # Finds out whether a domain's DNS provider supports Domain Connect, and if so where to
  # send the tenant to approve our records.
  #
  # Two hops, both defined by the Domain Connect spec:
  #   1. TXT at _domainconnect.<domain> names the provider's settings host.
  #   2. GET https://<settings-host>/v2/<domain>/settings returns urlSyncUX and providerId.
  #
  # Every failure path returns unsupported rather than raising. Domain Connect is an
  # accelerator on top of the manual record table, never a prerequisite: Cloudflare does not
  # implement it at all, and a provider can withdraw support at any time. If this cannot
  # answer confidently, the tenant copies the records by hand and nothing is lost.
  class Discovery
    Result = Struct.new(
      :supported, :provider_id, :provider_name, :url_sync_ux, :width, :height, :error,
      keyword_init: true
    ) do
      def supported? = !!supported
    end

    HTTP_TIMEOUT = 5
    DNS_TIMEOUT = 3

    def self.call(domain)
      new(domain).call
    end

    def initialize(domain)
      @domain = domain.to_s.downcase.strip
    end

    def call
      return unsupported('No domain given') if @domain.blank?

      host = settings_host
      return unsupported('DNS provider does not advertise Domain Connect') if host.blank?

      settings = fetch_settings(host)
      return unsupported('Could not read provider settings') if settings.nil?

      sync_url = settings['urlSyncUX'].presence
      return unsupported('Provider does not support the synchronous flow') if sync_url.blank?

      Result.new(
        supported: true,
        provider_id: settings['providerId'],
        provider_name: settings['providerDisplayName'].presence || settings['providerName'],
        url_sync_ux: sync_url.chomp('/'),
        width: settings['width'],
        height: settings['height']
      )
    rescue StandardError => e
      Rails.logger.warn("[DomainConnect::Discovery] #{@domain}: #{e.class}: #{e.message}")
      unsupported('Discovery failed')
    end

    private

    def unsupported(reason)
      Result.new(supported: false, error: reason)
    end

    def settings_host
      Dns::Lookup.txt("_domainconnect.#{@domain}", timeout: DNS_TIMEOUT).find(&:present?)
    end

    def fetch_settings(host)
      # The host comes from a DNS record on a domain the tenant controls, so it is not
      # trusted input. Force https and reject anything that is not a plain hostname before
      # making a request, so a crafted TXT record cannot point us at an internal address.
      return nil unless host.match?(/\A[a-z0-9]([a-z0-9\-.]*[a-z0-9])?\z/i)

      uri = URI::HTTPS.build(host: host, path: "/v2/#{@domain}/settings")
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                                                     open_timeout: HTTP_TIMEOUT,
                                                     read_timeout: HTTP_TIMEOUT) do |http|
        http.get(uri.request_uri)
      end

      return nil unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    rescue StandardError => e
      Rails.logger.warn("[DomainConnect::Discovery] settings fetch failed for #{host}: #{e.message}")
      nil
    end
  end
end
