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

    def txt(name, timeout: DEFAULT_TIMEOUT)
      resolve(name, Resolv::DNS::Resource::IN::TXT, timeout: timeout) { |r| r.strings.join }
    end

    def cname(name, timeout: DEFAULT_TIMEOUT)
      resolve(name, Resolv::DNS::Resource::IN::CNAME, timeout: timeout) { |r| r.name.to_s }
    end

    def mx(name, timeout: DEFAULT_TIMEOUT)
      resolve(name, Resolv::DNS::Resource::IN::MX, timeout: timeout) { |r| r.exchange.to_s }
    end

    def ns(name, timeout: DEFAULT_TIMEOUT)
      resolve(name, Resolv::DNS::Resource::IN::NS, timeout: timeout) { |r| r.name.to_s.downcase }
    end

    # Returns [] on any resolution failure. Callers that must distinguish "no records" from
    # "could not ask" should use resolve! instead: for a collision check, an unanswered
    # query is not the same as a free name.
    def resolve(name, type, timeout: DEFAULT_TIMEOUT, &block)
      resolve!(name, type, timeout: timeout, &block)
    rescue StandardError => e
      Rails.logger.warn("[Dns::Lookup] #{type.to_s.split('::').last} lookup failed for #{name}: #{e.message}")
      []
    end

    def resolve!(name, type, timeout: DEFAULT_TIMEOUT)
      return [] if name.blank?

      # No arguments to open. Anything passed here is nameserver config, never a timeout.
      Resolv::DNS.open do |dns|
        dns.timeouts = timeout
        dns.getresources(name.to_s, type).map { |r| yield(r) }
      end
    end
  end
end
