# frozen_string_literal: true

require 'resolv'

module Dns
  # The single place this codebase talks to DNS.
  #
  # It exists because of one mistake repeated in four files: Resolv::DNS.open(timeouts: 3).
  # That argument is treated as nameserver configuration, not a timeout, so it builds a
  # resolver that answers nothing — and it never raises, it just returns an empty array.
  #
  # The result was four features that failed silently and looked like someone else's fault:
  # registrar detection always fell back to generic instructions, Domain Connect always
  # reported unsupported, the MAIL FROM collision check always reported the subdomain free,
  # and DNS verification told tenants their correctly published records were missing.
  #
  # Every spec stubbed Resolv::DNS, so the call signature itself was never exercised. One
  # call site means one thing to get right, and dns_lookup_spec pins the signature.
  module Lookup
    DEFAULT_TIMEOUT = 3

    module_function

    # Pass zone: (the registrable domain, e.g. cbhms.com) to ask that zone's own name
    # server instead of the container's recursive resolver. See #fresh for why.
    def txt(name, timeout: DEFAULT_TIMEOUT, zone: nil)
      fresh(name, Resolv::DNS::Resource::IN::TXT, zone: zone, timeout: timeout) { |r| r.strings.join }
    end

    def cname(name, timeout: DEFAULT_TIMEOUT, zone: nil)
      fresh(name, Resolv::DNS::Resource::IN::CNAME, zone: zone, timeout: timeout) { |r| r.name.to_s }
    end

    def mx(name, timeout: DEFAULT_TIMEOUT, zone: nil)
      fresh(name, Resolv::DNS::Resource::IN::MX, zone: zone, timeout: timeout) { |r| r.exchange.to_s }
    end

    def ns(name, timeout: DEFAULT_TIMEOUT)
      resolve(name, Resolv::DNS::Resource::IN::NS, timeout: timeout) { |r| r.name.to_s.downcase }
    end

    def a(name, timeout: DEFAULT_TIMEOUT)
      resolve(name, Resolv::DNS::Resource::IN::A, timeout: timeout) { |r| r.address.to_s }
    end

    # Resolv has no CAA class, so the record arrives as raw RDATA: one flags byte, one
    # tag-length byte, the tag, then the value. A CNAME in the answer is followed, which is
    # what a CA does too: a CNAME to another host inherits that host's CAA set. That is how
    # Vercel's CAA list blocked a dealer's certificate from a zone the dealer controlled.
    CAA = Resolv::DNS::Resource::Generic.create(257, Resolv::DNS::Resource::IN::ClassValue)

    def caa(name, timeout: DEFAULT_TIMEOUT)
      resolve(name, CAA, timeout: timeout) do |r|
        data = r.data.to_s.b
        tag_length = data.getbyte(1).to_i
        { flags: data.getbyte(0).to_i,
          tag: data[2, tag_length].to_s.downcase,
          value: data[(2 + tag_length)..].to_s.force_encoding('UTF-8') }
      end
    end

    # TTL as the zone publishes it, asked of the zone's own name server. A recursive
    # resolver reports whatever is left on its cached copy, which can read as a few seconds
    # for a record that is really held for a week.
    def authoritative_ttl(name, type, zone:, timeout: DEFAULT_TIMEOUT)
      ip = authoritative_server(zone, timeout: timeout)
      return nil if ip.blank?

      resolve(name, type, timeout: timeout, nameserver: ip, &:ttl).max
    end

    # The answer as the zone publishes it right now.
    #
    # The container's resolver keeps an answer for the record's TTL. A dealer who fixes a
    # CNAME at GoDaddy (which saves it with a 3600 TTL) was told by Check DNS that it still
    # pointed at the old host for up to an hour, while every public resolver had the new
    # value: the www.cbhms.com setup on 2026-11-13. A verification check wants the uncached
    # answer, so ask the zone's own name server.
    #
    # Falls back to the ordinary lookup when there is no zone, the name server cannot be
    # found or reached, or it has nothing (a subdomain delegated elsewhere answers there).
    def fresh(name, type, zone:, timeout: DEFAULT_TIMEOUT, &block)
      if zone.present?
        ip = authoritative_server(zone, timeout: timeout)
        if ip.present?
          begin
            values = resolve!(name, type, timeout: timeout, nameserver: ip, &block)
            return values if values.any?
          rescue StandardError => e
            Rails.logger.warn("[Dns::Lookup] authoritative lookup failed for #{name} at #{ip}: #{e.message}")
          end
        end
      end

      resolve(name, type, timeout: timeout, &block)
    end

    # An address for one of the zone's own name servers, or nil.
    def authoritative_server(zone, timeout: DEFAULT_TIMEOUT)
      server = ns(zone, timeout: timeout).first
      return nil if server.blank?

      a(server, timeout: timeout).first.presence
    end

    # Returns [] on any resolution failure. Callers that must distinguish "no records" from
    # "could not ask" should use resolve! instead: for a collision check, an unanswered
    # query is not the same as a free name.
    def resolve(name, type, timeout: DEFAULT_TIMEOUT, nameserver: nil, &block)
      resolve!(name, type, timeout: timeout, nameserver: nameserver, &block)
    rescue StandardError => e
      Rails.logger.warn("[Dns::Lookup] #{type.to_s.split('::').last} lookup failed for #{name}: #{e.message}")
      []
    end

    def resolve!(name, type, timeout: DEFAULT_TIMEOUT, nameserver: nil)
      return [] if name.blank?

      # No arguments to open unless a specific server is wanted. Anything passed here is
      # nameserver config, never a timeout.
      config = nameserver ? [{ nameserver: [nameserver] }] : []
      Resolv::DNS.open(*config) do |dns|
        dns.timeouts = timeout
        dns.getresources(name.to_s, type).map { |r| yield(r) }
      end
    end
  end
end
