# frozen_string_literal: true

module SiteProfiles
  # SSRF guard for the site scanner.
  #
  # We fetch a URL supplied by a platform admin from inside our own network, so
  # every hop has to be re-checked: an allowed public hostname can 302 straight
  # to 169.254.169.254 and read cloud metadata. Resolving DNS ourselves and
  # checking the resolved addresses (not the hostname) is the only way to catch
  # a name that simply points at a private IP.
  #
  # Deliberately allowlist-by-scheme and denylist-by-address; anything we cannot
  # classify is rejected.
  module UrlGuard
    class BlockedUrlError < StandardError; end

    ALLOWED_SCHEMES = %w[http https].freeze

    # RFC1918 + loopback + link-local (incl. cloud metadata at 169.254.169.254)
    # + CGNAT + IPv6 loopback/ULA/link-local.
    BLOCKED_RANGES = [
      IPAddr.new('0.0.0.0/8'),
      IPAddr.new('10.0.0.0/8'),
      IPAddr.new('100.64.0.0/10'),
      IPAddr.new('127.0.0.0/8'),
      IPAddr.new('169.254.0.0/16'),
      IPAddr.new('172.16.0.0/12'),
      IPAddr.new('192.0.0.0/24'),
      IPAddr.new('192.168.0.0/16'),
      IPAddr.new('198.18.0.0/15'),
      IPAddr.new('224.0.0.0/4'),
      IPAddr.new('240.0.0.0/4'),
      IPAddr.new('::1/128'),
      IPAddr.new('fc00::/7'),
      IPAddr.new('fe80::/10')
    ].freeze

    module_function

    # Validates a URL and returns the parsed URI plus its resolved addresses.
    # Raises BlockedUrlError with a caller-safe message on anything suspicious.
    def validate!(url)
      uri = begin
        URI.parse(url.to_s.strip)
      rescue URI::InvalidURIError
        raise BlockedUrlError, 'That does not look like a valid URL.'
      end

      unless ALLOWED_SCHEMES.include?(uri.scheme)
        raise BlockedUrlError, 'Only http and https URLs can be scanned.'
      end
      raise BlockedUrlError, 'That URL is missing a hostname.' if uri.host.blank?

      addresses = resolve(uri.host)
      raise BlockedUrlError, "Could not resolve #{uri.host}." if addresses.empty?

      addresses.each do |addr|
        if blocked?(addr)
          # Do not echo the address back — that turns the error into a DNS
          # rebinding oracle for internal network mapping.
          raise BlockedUrlError, "#{uri.host} resolves to a non-public address and cannot be scanned."
        end
      end

      [uri, addresses]
    end

    def safe?(url)
      validate!(url)
      true
    rescue BlockedUrlError
      false
    end

    def blocked?(address)
      ip = address.is_a?(IPAddr) ? address : IPAddr.new(address.to_s)
      return true if ip.loopback? || ip.private? || ip.link_local?

      BLOCKED_RANGES.any? { |range| range.include?(ip) }
    rescue IPAddr::InvalidAddressError
      true
    end

    def resolve(host)
      # Literal IPs skip DNS but still get range-checked by the caller.
      return [IPAddr.new(host)] if literal_ip?(host)

      Addrinfo.getaddrinfo(host, nil, nil, :STREAM)
              .map { |ai| IPAddr.new(ai.ip_address) }
              .uniq
    rescue SocketError, IPAddr::InvalidAddressError
      []
    end

    def literal_ip?(host)
      IPAddr.new(host)
      true
    rescue IPAddr::InvalidAddressError
      false
    end
  end
end
