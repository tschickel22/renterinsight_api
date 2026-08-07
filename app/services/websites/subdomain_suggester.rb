# frozen_string_literal: true

module Websites
  # Turns a business name into an address a visitor could actually type.
  #
  # Every site needs one, because a subdomain is the only address a site has
  # until someone buys a domain — and websites were being created with none at
  # all, so a dealer published a site and had nowhere to send anyone.
  #
  # Global, not per company: a subdomain resolves to exactly one site across all
  # tenants (Websites::HostResolver#from_subdomain), so uniqueness is checked
  # against every website there is.
  class SubdomainSuggester
    # Hostnames that already mean something on the site host zone, plus the
    # usual infrastructure names. Handing out "origin" or "connect" would point
    # a dealer's site at the Cloudflare for SaaS plumbing every custom domain
    # depends on; the rest are reserved because someone will eventually want
    # them and a dealer should not be squatting on "api".
    RESERVED = %w[
      origin connect www api app admin mail smtp imap ftp ns ns1 ns2 dns
      staging stage test dev preview demo cdn assets static media img images
      status help support docs blog shop store account accounts billing
      dashboard portal login signin signup auth sso webhook webhooks
      mydealertide dealertide renterinsight
    ].freeze

    MIN_LENGTH = 3
    MAX_LENGTH = 40

    class << self
      # @param name [String] a business or site name
      # @param taken [Proc, nil] override for testing; defaults to a DB check
      # @return [String, nil] a free, valid subdomain, or nil if name is unusable
      def suggest(name, exclude_website_id: nil, taken: nil)
        base = normalize(name)
        return nil if base.blank?

        is_taken = taken || ->(candidate) { taken_in_db?(candidate, exclude_website_id) }
        return base unless reserved?(base) || is_taken.call(base)

        # -2, -3, ... rather than random noise: a dealer reading their own URL
        # should be able to recognise and remember it.
        (2..99).each do |n|
          candidate = "#{truncate_for_suffix(base, n)}-#{n}"
          return candidate unless reserved?(candidate) || is_taken.call(candidate)
        end
        nil
      end

      # Sanitises without checking availability. Used to validate what a human
      # typed, so the rules a suggestion follows and the rules an edit must obey
      # are the same rules.
      def normalize(name)
        value = name.to_s.downcase
                    .gsub(/['’]/, '')          # o'brien -> obrien, not o-brien
                    .gsub(/&/, ' and ')
                    .gsub(/[^a-z0-9]+/, '-')
                    .gsub(/-+/, '-')
                    .delete_prefix('-').delete_suffix('-')

        return nil if value.length < MIN_LENGTH

        value[0, MAX_LENGTH].delete_suffix('-')
      end

      def reserved?(candidate)
        RESERVED.include?(candidate.to_s.downcase)
      end

      def valid?(candidate)
        value = candidate.to_s
        return false if value.length < MIN_LENGTH || value.length > MAX_LENGTH
        return false if reserved?(value)

        value.match?(/\A[a-z0-9]+(-[a-z0-9]+)*\z/)
      end

      private

      def taken_in_db?(candidate, exclude_website_id)
        scope = Website.where(subdomain: candidate)
        scope = scope.where.not(id: exclude_website_id) if exclude_website_id
        scope.exists?
      end

      # Keeps the suffix inside MAX_LENGTH rather than pushing past it.
      def truncate_for_suffix(base, n)
        room = MAX_LENGTH - n.to_s.length - 1
        base.length <= room ? base : base[0, room].delete_suffix('-')
      end
    end
  end
end
