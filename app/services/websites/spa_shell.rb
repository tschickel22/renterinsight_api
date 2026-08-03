# frozen_string_literal: true

require 'net/http'

module Websites
  # Fetches the single-page app's index.html so Rails can serve a tenant site on the
  # tenant's own hostname while the existing React renderer still draws the page body.
  #
  # Rails cannot simply link the SPA's assets by name: the bundle filenames are content
  # hashed and change on every frontend deploy. Fetching the real index.html means the
  # script and style tags are always whatever the current deploy produced, with no version
  # coupling between the two repos.
  #
  # Cached, because this sits in the request path of every page view on every dealer site,
  # and the underlying document only changes on a frontend deploy.
  class SpaShell
    CACHE_KEY = 'websites:spa_shell'
    CACHE_TTL = 10.minutes
    HTTP_TIMEOUT = 5

    class ShellUnavailable < StandardError; end

    def self.fetch
      new.fetch
    end

    # Digest of the current shell, used in page ETags. A frontend deploy changes the asset
    # filenames in the shell, which changes this, which invalidates cached HTML that would
    # otherwise keep pointing at the previous bundle.
    def self.version
      Digest::SHA256.hexdigest(fetch.to_s)[0, 16]
    rescue ShellUnavailable
      'unavailable'
    end

    def fetch
      cached = Rails.cache.read(CACHE_KEY)
      return cached if cached.present?

      html = download
      Rails.cache.write(CACHE_KEY, html, expires_in: CACHE_TTL)
      html
    end

    # The SPA origin serves relative asset paths ("/assets/index-abc123.js"). Served from a
    # dealer's hostname those would resolve against the dealer domain and 404, so they are
    # rewritten to absolute URLs on the SPA origin.
    def self.absolutize(html, origin)
      html.gsub(%r{(<(?:script|link)\b[^>]*?\b(?:src|href)=")(/[^/"][^"]*)"}i) do
        "#{Regexp.last_match(1)}#{origin}#{Regexp.last_match(2)}\""
      end
    end

    private

    MAX_REDIRECTS = 3

    def download
      final_uri, response = get_following_redirects(URI.parse(origin))

      raise ShellUnavailable, "SPA origin returned #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      # Assets resolve against wherever the shell actually came from, not where we started.
      # A host that redirects to its canonical name would otherwise have its asset paths
      # rewritten to a hostname that only redirects.
      base = "#{final_uri.scheme}://#{final_uri.host}"
      base += ":#{final_uri.port}" unless final_uri.port == final_uri.default_port

      self.class.absolutize(utf8(response.body), base)
    rescue ShellUnavailable
      raise
    rescue StandardError => e
      raise ShellUnavailable, "Could not fetch SPA shell: #{e.message}"
    end

    # Follows redirects, because a host redirecting to its canonical name is ordinary
    # Netlify behaviour between domain aliases. Treating a 301 as unavailable took every
    # dealer site down with "Site temporarily unavailable" over a working origin.
    def get_following_redirects(uri, remaining = MAX_REDIRECTS)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                                                     open_timeout: HTTP_TIMEOUT,
                                                     read_timeout: HTTP_TIMEOUT) do |http|
        http.get(uri.path.presence || '/')
      end

      return [uri, response] unless response.is_a?(Net::HTTPRedirection)
      raise ShellUnavailable, 'SPA origin redirected too many times' if remaining.zero?

      location = URI.join(uri, response['Location'].to_s)
      # Never downgrade to plain http chasing a redirect.
      raise ShellUnavailable, "SPA origin redirected to #{location.scheme}" unless location.scheme == 'https'

      get_following_redirects(location, remaining - 1)
    end

    # Net::HTTP hands back ASCII-8BIT unless the response declares a charset it recognises.
    # Every page then died with Encoding::CompatibilityError the moment the binary body met
    # the UTF-8 string literals used to inject the head tags, which surfaced as a bare 500
    # with nothing pointing at encoding.
    #
    # scrub rather than raise on invalid bytes: a stray byte in the shell should not take
    # every dealer site down.
    def utf8(body)
      text = body.to_s.dup.force_encoding(Encoding::UTF_8)
      text.valid_encoding? ? text : text.scrub
    end

    def origin
      (ENV['WEBSITE_SPA_ORIGIN'].presence || ENV['FRONTEND_URL'].presence).to_s.chomp('/')
    end
  end
end
