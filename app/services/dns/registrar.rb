# frozen_string_literal: true

require 'resolv'

module Dns
  # Identifies where a domain's DNS is actually managed, so the sending-domain screen can
  # give instructions for that provider instead of generic ones.
  #
  # Worth the effort because the generic instructions are the thing that fails. Every
  # provider labels the same field differently ("Host", "Name", "Hostname"), and most treat
  # it as relative to the domain, so a tenant who pastes the fully qualified name we show
  # them creates dkim._domainkey.example.com.example.com and waits days for a verification
  # that can never happen. We hit exactly that risk ourselves on GoDaddy.
  #
  # Detection is from the live NS records rather than from the registrar of record, because
  # DNS is frequently delegated away from where the domain was bought.
  class Registrar
    CACHE_TTL = 1.hour
    DNS_TIMEOUT = 3

    # Matched against the authoritative nameservers, longest suffix first.
    PROVIDERS = {
      'domaincontrol.com' => :godaddy,
      'ns.cloudflare.com' => :cloudflare,
      'registrar-servers.com' => :namecheap,
      'awsdns' => :route53,
      'googledomains.com' => :google,
      'nsone.net' => :netlify,
      'netlify.com' => :netlify,
      'vercel-dns.com' => :vercel,
      'wixdns.net' => :wix,
      'squarespacedns.com' => :squarespace,
      'ui-dns' => :ionos,
      '1and1' => :ionos,
      'worldnic.com' => :network_solutions,
      'name.com' => :name_com,
      'hover.com' => :hover,
      'dreamhost.com' => :dreamhost,
      'bluehost.com' => :bluehost,
      'hostgator.com' => :hostgator,
      'launchpad.net' => :hostgator,
      'digitalocean.com' => :digitalocean
    }.freeze

    # Whether the provider can point a bare domain (example.com, no subdomain) at a CNAME
    # target. DNS forbids a CNAME at the zone apex, so this only works where the provider
    # offers ALIAS, ANAME or CNAME flattening. Everywhere else the dealer has to put the
    # site on www and forward the apex to it.
    APEX_ALIAS_SUPPORT = %i[cloudflare route53 namecheap netlify vercel].freeze

    def self.supports_apex_alias?(key)
      APEX_ALIAS_SUPPORT.include?(key&.to_sym)
    end

    DETAILS = {
      godaddy: {
        name: 'GoDaddy',
        url: 'https://dcc.godaddy.com/manage/dns',
        field_label: 'Name',
        relative: true,
        forwarding_hint: 'In GoDaddy, open your domain and use Forwarding to send the bare ' \
                         'domain to the www version.',
        steps: [
          'Sign in to GoDaddy and open My Products.',
          'Find your domain and click DNS, then Manage Zones.',
          'Click Add New Record and choose the record type.',
          'Paste the Name and Value exactly as shown, then Save.'
        ]
      },
      cloudflare: {
        name: 'Cloudflare',
        url: 'https://dash.cloudflare.com',
        field_label: 'Name',
        relative: true,
        steps: [
          'Open the Cloudflare dashboard and select your domain.',
          'Go to DNS, then Records, and click Add record.',
          'Set Proxy status to DNS only (grey cloud), not Proxied.',
          'Paste the Name and Value exactly as shown, then Save.'
        ],
        # The single most common Cloudflare failure. An orange-clouded CNAME resolves to
        # Cloudflare's own address, so the DKIM lookup never reaches amazonses.com.
        warning: 'DKIM records must be set to "DNS only" (grey cloud). A proxied (orange) ' \
                 'record will never verify.'
      },
      namecheap: {
        name: 'Namecheap',
        url: 'https://ap.www.namecheap.com/domains/list',
        field_label: 'Host',
        relative: true,
        steps: [
          'Sign in to Namecheap and open Domain List, then Manage.',
          'Open the Advanced DNS tab.',
          'Click Add New Record and choose the record type.',
          'Paste the Host and Value exactly as shown, then save with the tick.'
        ]
      },
      route53: {
        name: 'AWS Route 53',
        url: 'https://console.aws.amazon.com/route53/v2/hostedzones',
        field_label: 'Record name',
        relative: true,
        steps: [
          'Open Route 53 and select your hosted zone.',
          'Click Create record.',
          'Enter the record name, choosing the record type.',
          'Paste the value exactly as shown, then Create records.'
        ]
      },
      google: {
        name: 'Google Domains / Squarespace',
        url: 'https://domains.squarespace.com',
        field_label: 'Host name',
        relative: true,
        steps: [
          'Open your domain and go to DNS settings.',
          'Under Custom records, click Add record.',
          'Paste the host name and data exactly as shown, then Save.'
        ]
      },
      squarespace: {
        name: 'Squarespace',
        url: 'https://account.squarespace.com/domains',
        field_label: 'Host',
        relative: true,
        steps: [
          'Open Domains, select your domain, then DNS Settings.',
          'Click Add Record under Custom Records.',
          'Paste the host and data exactly as shown, then Save.'
        ]
      },
      netlify: {
        name: 'Netlify',
        url: 'https://app.netlify.com',
        field_label: 'Name',
        relative: true,
        steps: [
          'Open Domains, select your domain, then DNS panel.',
          'Click Add new record and choose the record type.',
          'Paste the name and value exactly as shown, then Save.'
        ]
      },
      vercel: {
        name: 'Vercel',
        url: 'https://vercel.com/dashboard/domains',
        field_label: 'Name',
        relative: true,
        steps: [
          'Open Domains and select your domain.',
          'Under DNS Records, choose the record type.',
          'Paste the name and value exactly as shown, then Add.'
        ]
      },
      wix: {
        name: 'Wix',
        url: 'https://www.wix.com/my-account/domains',
        field_label: 'Host name',
        relative: true,
        steps: [
          'Open Domains, select your domain, then Advanced, then Edit DNS.',
          'Find the section for the record type and click Add Record.',
          'Paste the host name and value exactly as shown, then Save.'
        ]
      },
      ionos: {
        name: 'IONOS',
        url: 'https://my.ionos.com/domains',
        field_label: 'Host name',
        relative: true,
        steps: [
          'Open Domains & SSL, select your domain, then DNS.',
          'Click Add record and choose the record type.',
          'Paste the host name and value exactly as shown, then Save.'
        ]
      },
      network_solutions: {
        name: 'Network Solutions',
        url: 'https://www.networksolutions.com/my-account',
        field_label: 'Host',
        relative: true,
        steps: [
          'Sign in and open My Domain Names, then Manage.',
          'Choose Change Where Domain Points, then Advanced DNS.',
          'Add the record and paste the host and value exactly as shown.'
        ]
      },
      name_com: {
        name: 'Name.com',
        url: 'https://www.name.com/account/domain',
        field_label: 'Host',
        relative: true,
        steps: [
          'Open your domain and click DNS Records.',
          'Choose the record type and paste the host and answer exactly as shown.',
          'Click Add Record.'
        ]
      },
      hover: {
        name: 'Hover',
        url: 'https://hover.com/control_panel',
        field_label: 'Hostname',
        relative: true,
        steps: [
          'Open your domain and go to the DNS tab.',
          'Click Add A Record and choose the record type.',
          'Paste the hostname and value exactly as shown, then Save.'
        ]
      },
      dreamhost: {
        name: 'DreamHost',
        url: 'https://panel.dreamhost.com/index.cgi?tree=domain.manage',
        field_label: 'Name',
        relative: true,
        steps: [
          'Open Domains, then Manage Domains, then DNS for your domain.',
          'Under Add a custom DNS record, choose the type.',
          'Paste the name and value exactly as shown, then Add Record Now.'
        ]
      },
      bluehost: {
        name: 'Bluehost',
        url: 'https://my.bluehost.com/hosting/domains',
        field_label: 'Host Record',
        relative: true,
        steps: [
          'Open Domains, select your domain, then DNS.',
          'Click Add Record and choose the record type.',
          'Paste the host record and value exactly as shown, then Save.'
        ]
      },
      hostgator: {
        name: 'HostGator',
        url: 'https://portal.hostgator.com',
        field_label: 'Host Record',
        relative: true,
        steps: [
          'Sign in to the Customer Portal and open Domains.',
          'Select your domain, then Manage DNS.',
          'Add the record and paste the host and value exactly as shown.'
        ]
      },
      digitalocean: {
        name: 'DigitalOcean',
        url: 'https://cloud.digitalocean.com/networking/domains',
        field_label: 'Hostname',
        relative: true,
        steps: [
          'Open Networking, then Domains, and select your domain.',
          'Choose the record type tab.',
          'Paste the hostname and value exactly as shown, then Create Record.'
        ]
      }
    }.freeze

    GENERIC = {
      name: nil,
      url: nil,
      field_label: 'Host',
      relative: true,
      steps: [
        'Sign in wherever your domain\'s DNS is managed.',
        'Find the DNS records or zone editor for this domain.',
        'Add each record below, choosing the matching record type.',
        'Paste the name and value exactly as shown, then save.'
      ]
    }.freeze

    def self.for(hostname)
      new(hostname).detect
    end

    def initialize(hostname)
      @hostname = hostname.to_s.downcase.strip
    end

    def detect
      return generic if @hostname.blank?

      key = Rails.cache.fetch("dns_registrar:#{@hostname}", expires_in: CACHE_TTL) do
        provider_key_from_nameservers.to_s
      end

      details = DETAILS[key.presence&.to_sym] || GENERIC
      details.merge(
        key: key.presence,
        supports_apex_alias: self.class.supports_apex_alias?(key.presence),
        # The relative/absolute distinction is the one that actually breaks verification, so
        # it is surfaced as data rather than buried in prose.
        example_host: example_host(details)
      )
    end

    private

    def generic
      GENERIC.merge(key: nil, supports_apex_alias: false, example_host: example_host(GENERIC))
    end

    def provider_key_from_nameservers
      servers = nameservers
      return nil if servers.empty?

      PROVIDERS.each do |suffix, key|
        return key if servers.any? { |ns| ns.include?(suffix) }
      end
      nil
    end

    def nameservers
      Dns::Lookup.ns(@hostname, timeout: DNS_TIMEOUT)
    end

    # Shows the tenant what the field should contain for their provider, using a DKIM record
    # as the example since that is the one that must be right.
    def example_host(details)
      return "token._domainkey.#{@hostname}" unless details[:relative]

      'token._domainkey'
    end
  end
end
