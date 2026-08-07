# frozen_string_literal: true

module Constraints
  # Matches a request only when its Host belongs to a published tenant website.
  #
  # Sits on a catch-all route, so it has to be cheap and it has to be certain. Cheap because
  # it runs on every request that falls through to it, and certain because a false positive
  # would hand an unrelated request to a dealer's site.
  #
  # Results are cached both ways. Caching only the hits would leave every request to the API
  # host doing a database lookup to rediscover that it is not a dealer site.
  class TenantWebsiteHost
    CACHE_TTL = 5.minutes
    NEGATIVE_CACHE_TTL = 1.minute

    def self.matches?(request)
      new.matches?(request)
    end

    # Paths that must always reach the application, even when the request arrives on a
    # dealer hostname. These routes are matched before the tenant catch-all, so without
    # this a dealer domain would swallow API and webhook traffic.
    #
    # /pv/ is the landing page tracking beacon. The visitor's browser calls it on the
    # dealer's own hostname, so without it here the catch-all would answer with the
    # landing page's HTML and every visit would go unrecorded.
    RESERVED_PREFIXES = %w[
      /api /webhook /webhooks /rails /up /assets /uploads /t/ /u/ /q/ /f/ /sign/ /pv/
    ].freeze

    def matches?(request)
      # Dealer traffic arrives through a Worker that rewrites Host so Render will accept it,
      # carrying the real hostname in a verified header. Reading request.host here would see
      # the Render service hostname and route every dealer site to the API instead.
      host = Websites::RequestHost.for(request)
      return false if host.blank?
      return false if platform_host?(host)
      return false if reserved_path?(request.path)

      cache_key = "tenant_website_host:#{host}"
      cached = Rails.cache.read(cache_key)
      return cached unless cached.nil?

      matched = Websites::HostResolver.call(host).present?
      # Negative answers expire faster so a domain that was just verified starts working
      # within a minute rather than five.
      Rails.cache.write(cache_key, matched, expires_in: matched ? CACHE_TTL : NEGATIVE_CACHE_TTL)
      matched
    rescue StandardError => e
      # Never let a lookup failure turn into a 500 on an unrelated request. Falling through
      # means the request continues to whatever would have handled it before.
      Rails.logger.error("[TenantWebsiteHost] #{e.class}: #{e.message}")
      false
    end

    private

    def reserved_path?(path)
      p = path.to_s
      RESERVED_PREFIXES.any? { |prefix| p == prefix.chomp('/') || p.start_with?(prefix) }
    end

    # The API's own hostnames can never be a dealer site, and short-circuiting them keeps
    # this off the hot path for ordinary API traffic entirely.
    def platform_host?(host)
      return true if host.end_with?('.onrender.com')
      return true if host == 'localhost' || host == '127.0.0.1'

      platform_hosts.include?(host)
    end

    def platform_hosts
      @platform_hosts ||= [
        ENV['DMS_API_URL'], ENV['APP_URL'], ENV['FRONTEND_URL']
      ].compact_blank.filter_map do |url|
        URI.parse(url).host&.downcase
      rescue URI::InvalidURIError
        nil
      end
    end
  end
end
