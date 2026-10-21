# frozen_string_literal: true

module Dns
  # Reads a hostname's DNS as it stands today, before a dealer adds it, and names what will
  # get in the way of the certificate.
  #
  # Written after www.easyhomesource.com (2026-10-20). Every record we asked for was
  # published correctly and the certificate still could not issue, for two reasons nothing
  # in the flow could see:
  #
  # 1. The hostname was a CNAME to Vercel, and a CA reads CAA through a CNAME. Vercel's
  #    list allowed Let's Encrypt, Google, Sectigo and GlobalSign. Cloudflare picked
  #    SSL.com, and on our plan the CA cannot be chosen, so issuance was refused.
  # 2. That CNAME had a one week TTL. Once the dealer replaced it, resolvers (including the
  #    CA's) kept answering with the old one, so the fix could not take effect for days.
  #
  # Both are visible before anything is created. Neither can be fixed by us, only by the
  # dealer at their DNS host, and only cheaply if they know before they start.
  class PreFlight
    # Cloudflare picks among these for custom hostnames and we cannot choose on our plan,
    # so a CAA set has to allow all three or issuance can fail on any given attempt.
    ISSUERS = {
      'letsencrypt.org' => "Let's Encrypt",
      'pki.goog' => 'Google Trust Services',
      'ssl.com' => 'SSL.com'
    }.freeze

    # Anything cached longer than this delays the switch noticeably. Ten minutes is what we
    # ask dealers to set.
    LONG_TTL = 3600
    SUGGESTED_TTL = 600

    Issue = Struct.new(:key, :level, :headline, :detail, keyword_init: true)

    Result = Struct.new(:hostname, :current_type, :current_target, :current_addresses,
                        :points_at_us, :ttl, :caa_source, :caa_issuers, :caa_missing,
                        :issues, keyword_init: true) do
      # Serving something today that is not us. The dealer's site is live elsewhere, so
      # the certificate has to be issued before they switch or the site goes down.
      def live_elsewhere?
        !points_at_us && (current_target.present? || current_addresses.present?)
      end

      # HTTP validation needs traffic to reach Cloudflare, which it cannot while the
      # hostname points at the old host. TXT works from anywhere.
      def ssl_method
        live_elsewhere? ? 'txt' : 'http'
      end

      def as_json(*)
        {
          hostname: hostname,
          current_type: current_type,
          current_target: current_target,
          current_addresses: current_addresses,
          points_at_us: points_at_us,
          live_elsewhere: live_elsewhere?,
          ttl: ttl,
          caa_source: caa_source,
          caa_issuers: caa_issuers,
          caa_missing: caa_missing,
          ssl_method: ssl_method,
          issues: issues.map(&:to_h)
        }
      end
    end

    def self.for(hostname, our_target:)
      new(hostname, our_target: our_target).call
    end

    def initialize(hostname, our_target:)
      @hostname = hostname.to_s.downcase.strip.sub(%r{\Ahttps?://}, '').chomp('/').chomp('.')
      @our_target = our_target.to_s.downcase.chomp('.')
    end

    def call
      return empty_result if @hostname.blank?

      cname = Lookup.cname(@hostname).first.to_s.downcase.chomp('.').presence
      addresses = Lookup.a(@hostname)
      points_at_us = points_at_us?(cname, addresses)
      ttl = current_ttl(cname, addresses)
      caa_source, issuers = effective_caa(cname)
      missing = issuers.any? ? ISSUERS.keys - issuers : []

      result = Result.new(
        hostname: @hostname,
        current_type: cname ? 'CNAME' : ('A' if addresses.any?),
        current_target: cname,
        current_addresses: addresses,
        points_at_us: points_at_us,
        ttl: ttl,
        caa_source: caa_source,
        caa_issuers: issuers,
        caa_missing: missing,
        issues: []
      )
      result.issues = issues_for(result)
      result
    end

    private

    def empty_result
      Result.new(hostname: @hostname, current_addresses: [], points_at_us: false,
                 caa_issuers: [], caa_missing: [], issues: [])
    end

    def points_at_us?(cname, addresses)
      return false if @our_target.blank?
      return cname == @our_target if cname

      addresses.any? && (addresses & Lookup.a(@our_target)).any?
    end

    def current_ttl(cname, addresses)
      return nil if cname.nil? && addresses.empty?

      type = cname ? Resolv::DNS::Resource::IN::CNAME : Resolv::DNS::Resource::IN::A
      zone = zone_apex
      zone && Lookup.authoritative_ttl(@hostname, type, zone: zone)
    end

    # The zone that holds this hostname: the longest parent that has its own name servers.
    # A name that is itself a CNAME is skipped, because asking for its NS follows the CNAME
    # and answers with the other host's name servers.
    def zone_apex
      labels = @hostname.split('.')
      (1...(labels.length - 1)).each do |i|
        candidate = labels[i..].join('.')
        next if Lookup.cname(candidate).any?
        return candidate if Lookup.ns(candidate).any?
      end
      @hostname if Lookup.ns(@hostname).any?
    end

    # RFC 8659: the CAA set at the hostname (following a CNAME, as a CA does), else at each
    # parent in turn. The first non-empty set is the one that applies.
    def effective_caa(cname)
      labels = @hostname.split('.')
      (0...(labels.length - 1)).each do |i|
        name = labels[i..].join('.')
        issuers = Lookup.caa(name).select { |r| r[:tag] == 'issue' }
                                  .map { |r| r[:value].split(';').first.to_s.strip.downcase }
                                  .reject(&:blank?)
        next if issuers.empty?

        source = i.zero? && cname ? cname : name
        return [source, issuers.uniq]
      end
      [nil, []]
    end

    def issues_for(result)
      issues = []
      issues << live_elsewhere_issue(result) if result.live_elsewhere?
      issues << long_ttl_issue(result) if result.live_elsewhere? && result.ttl.to_i > LONG_TTL
      issues << caa_issue(result) if result.caa_missing.any?
      issues
    end

    def where_it_points(result)
      result.current_target || result.current_addresses.join(', ')
    end

    def live_elsewhere_issue(result)
      Issue.new(
        key: 'live_elsewhere', level: 'info',
        headline: 'Your current site stays up while we set this up',
        detail: "#{@hostname} points at #{where_it_points(result)} today. We will give you " \
                'TXT records that let the certificate be issued first. Change the ' \
                "#{result.current_type} record only after the certificate shows as issued, " \
                'so the site never goes down.'
      )
    end

    def long_ttl_issue(result)
      held = human_duration(result.ttl)
      Issue.new(
        key: 'long_ttl', level: 'warning',
        headline: "Lower the TTL on the current #{result.current_type} record first",
        detail: "It is set to #{held}, so after you change it some visitors, and the " \
                "certificate authority, can keep seeing #{where_it_points(result)} for up " \
                "to #{held}. Set its TTL to #{SUGGESTED_TTL} seconds today. Copies already " \
                "cached keep the old #{held} until they expire, so plan the final switch " \
                "for #{held} from now."
      )
    end

    def caa_issue(result)
      allowed = result.caa_issuers.join(', ')
      needed = result.caa_missing.map { |d| %(0 issue "#{d}") }.join(', ')
      inherited = result.current_target.present? && result.caa_source == result.current_target

      detail =
        if inherited
          "#{@hostname} is a CNAME to #{result.current_target}, so it takes that host's CAA " \
            "records, which only allow #{allowed}. We use #{ISSUERS.values.to_sentence}. " \
            'A CAA record cannot sit beside a CNAME, so before adding the domain here, ' \
            "replace the CNAME with an A record to #{result.current_addresses.join(', ').presence || 'the same site'} " \
            "and add these CAA records for #{@hostname}: #{needed}."
        else
          "The CAA records at #{result.caa_source} only allow #{allowed}. We use " \
            "#{ISSUERS.values.to_sentence}. Add these CAA records at #{result.caa_source}: #{needed}."
        end

      Issue.new(key: 'caa_blocked', level: 'warning',
                headline: 'CAA records will block the certificate', detail: detail)
    end

    def human_duration(seconds)
      seconds = seconds.to_i
      if seconds >= 86_400
        days = (seconds / 86_400.0).round
        "#{days} #{'day'.pluralize(days)}"
      elsif seconds >= 3600
        hours = (seconds / 3600.0).round
        "#{hours} #{'hour'.pluralize(hours)}"
      else
        minutes = [(seconds / 60.0).round, 1].max
        "#{minutes} #{'minute'.pluralize(minutes)}"
      end
    end
  end
end
