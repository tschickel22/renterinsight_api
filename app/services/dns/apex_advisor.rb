# frozen_string_literal: true

module Dns
  # Tells a tenant, before they commit, whether the hostname they typed can actually work.
  #
  # The trap this exists for: DNS forbids a CNAME at a zone apex, and Cloudflare for SaaS
  # routes by CNAME. So a dealer who enters sunshine-rv.com passes ownership verification,
  # publishes everything correctly, and then waits forever for a certificate that can never
  # issue. Nothing in the flow would have told them why, because every individual step
  # succeeded.
  #
  # Providers offering ALIAS, ANAME or CNAME flattening are exempt; the rest need the site
  # on www with the apex forwarded to it.
  class ApexAdvisor
    Result = Struct.new(:apex, :workable, :strategy, :headline, :detail, :suggested_hostname,
                        :registrar_name, keyword_init: true) do
      def apex? = !!apex
      def workable? = !!workable
    end

    def self.for(hostname)
      new(hostname).call
    end

    def initialize(hostname)
      @hostname = hostname.to_s.downcase.strip.sub(%r{\Ahttps?://}, '').chomp('/')
    end

    def call
      return not_apex if @hostname.blank? || !apex?

      registrar = Registrar.for(@hostname)

      if registrar[:supports_apex_alias]
        apex_supported(registrar)
      else
        apex_needs_www(registrar)
      end
    end

    private

    # A bare domain has exactly one dot for a simple TLD. Multi-part public suffixes
    # (co.uk, com.au) would otherwise read as subdomains, so those are treated as apex too.
    MULTI_PART_TLDS = %w[co.uk org.uk me.uk com.au net.au org.au co.nz co.za com.br co.in].freeze

    def apex?
      labels = @hostname.split('.')
      return false if labels.length < 2

      suffix = labels.last(2).join('.')
      return labels.length == 3 if MULTI_PART_TLDS.include?(suffix)

      labels.length == 2
    end

    def not_apex
      Result.new(apex: false, workable: true, strategy: :subdomain)
    end

    def apex_supported(registrar)
      Result.new(
        apex: true, workable: true, strategy: :alias,
        registrar_name: registrar[:name],
        headline: "#{registrar[:name] || 'Your DNS provider'} can point a bare domain at us",
        detail: 'Add the record below as an ALIAS, ANAME or flattened CNAME rather than a ' \
                'plain CNAME. A plain CNAME is not permitted at a bare domain and will be rejected.',
        suggested_hostname: "www.#{@hostname}"
      )
    end

    def apex_needs_www(registrar)
      name = registrar[:name] || 'Your DNS provider'
      forwarding = registrar[:forwarding_hint].presence ||
                   'Most registrars offer domain forwarding under the domain settings.'

      Result.new(
        apex: true, workable: false, strategy: :www_with_forwarding,
        registrar_name: registrar[:name],
        headline: "#{name} cannot point a bare domain at us",
        detail: "DNS does not allow a bare domain to be a CNAME, and #{name} has no ALIAS " \
                "record to work around it. Use www.#{@hostname} for the site, then forward " \
                "#{@hostname} to it so both addresses work. #{forwarding}",
        suggested_hostname: "www.#{@hostname}"
      )
    end
  end
end
