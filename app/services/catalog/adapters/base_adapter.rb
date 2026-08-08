# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'nokogiri'

module Catalog
  module Adapters
    # Shared adapter interface. One subclass per PLATFORM TYPE (not per site).
    # Each adapter converges its source onto Catalog::NormalizedHome.
    #
    # Contract:
    #   discover(limit:) -> [source_key, ...]   stable unique keys
    #   fetch(key)       -> raw payload (Hash/String) for one home
    #   parse(raw)       -> NormalizedHome
    #
    # Keep each FIELD extractor a small, individually testable method so a markup
    # change breaks ONE extractor (and shows up as a single dropped field rate),
    # not the whole run.
    class BaseAdapter
      USER_AGENT = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' \
                   '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
      REQUEST_TIMEOUT = 30

      attr_reader :source

      def initialize(source)
        @source = source
      end

      def discover(limit: nil)
        raise NotImplementedError, "#{self.class} must implement #discover"
      end

      def fetch(_key)
        raise NotImplementedError, "#{self.class} must implement #fetch"
      end

      def parse(_raw)
        raise NotImplementedError, "#{self.class} must implement #parse"
      end

      # Seconds to wait between fetches. Override per adapter (robots.txt).
      def crawl_delay
        Integer(source.config['crawl_delay'] || 10)
      end

      # The UA every request sends. Overridable per adapter and per source
      # because some hosts run a WAF that rejects the shared default outright
      # (adventurehomes.net answers it with a 403 page), and bumping the shared
      # constant would silently re-calibrate every other adapter.
      def user_agent
        (source.respond_to?(:config) && source.config.is_a?(Hash) &&
          source.config['user_agent'].presence) || USER_AGENT
      end

      # Dry-run for the admin "Test" action: discover a few keys, fetch+parse
      # each, return [NormalizedHome]. Never ingests. Resilient per-home so one
      # bad page doesn't sink the sample.
      def sample(limit: 5)
        Array(discover(limit: limit)).first(limit).filter_map do |key|
          raw = fetch(key)
          raw && parse(raw)
        rescue StandardError => e
          Rails.logger.warn "[#{self.class.name}] sample failed for #{key}: #{e.class}: #{e.message}"
          nil
        end
      end

      protected

      # Polite HTTP GET mirroring Scrapers::ChampionImsClient#http_get — browser
      # UA, timeouts, follows one redirect, returns nil (never raises) on failure.
      def http_get(url, accept: 'text/html,application/xhtml+xml')
        uri  = URI.parse(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl      = (uri.scheme == 'https')
        http.open_timeout = REQUEST_TIMEOUT
        http.read_timeout = REQUEST_TIMEOUT
        configure_ssl(http) if http.use_ssl?

        request = Net::HTTP::Get.new(uri.request_uri)
        request['User-Agent'] = user_agent
        request['Accept']     = accept

        response = http.request(request)

        case response
        when Net::HTTPOK then response.body
        when Net::HTTPRedirection
          loc = response['location']
          loc.present? ? http_get(absolute_url(loc, uri), accept: accept) : nil
        when Net::HTTPSuccess
          # 2xx that is NOT 200 is never page content we can parse. Hosts return
          # 202 with a tiny bot-challenge stub, and accepting it as a body meant
          # the challenge got parsed as the page: discovery found no links and
          # the run reported "0 homes discovered" as though the site were empty,
          # with nothing logged. Treat it as the failure it is.
          Rails.logger.error "[#{self.class.name}] HTTP #{response.code} (non-200 success) for #{url}; " \
                             "#{response.body.to_s.bytesize} bytes, treating as no content"
          nil
        else
          Rails.logger.error "[#{self.class.name}] HTTP #{response.code} for #{url}"
          nil
        end
      rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED,
             OpenSSL::SSL::SSLError => e
        Rails.logger.error "[#{self.class.name}] HTTP error for #{url}: #{e.class}: #{e.message}"
        nil
      end

      # Load the system CA bundle explicitly. Ruby's default cert store isn't
      # always populated in the Render runtime (-> "unable to get local issuer
      # certificate"), even though the OS ships ca-certificates. set_default_paths
      # picks up SSL_CERT_FILE / SSL_CERT_DIR / the OpenSSL defaults.
      #
      # A source may opt out of verification (config { "ssl_verify": false }) for
      # a site that serves an incomplete chain — read-only public scraping only.
      def configure_ssl(http)
        if source.respond_to?(:config) && source.config.is_a?(Hash) &&
           source.config['ssl_verify'] == false
          http.verify_mode = OpenSSL::SSL::VERIFY_NONE
          return
        end

        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        store = OpenSSL::X509::Store.new
        store.set_default_paths
        http.cert_store = store
      rescue StandardError => e
        Rails.logger.warn "[#{self.class.name}] SSL store setup failed: #{e.message}"
      end

      def doc_for(url)
        body = http_get(url)
        body && Nokogiri::HTML(body)
      end

      # Structured probe used by diagnostics — unlike http_get it does NOT
      # follow redirects or swallow non-2xx, so the caller sees the real status
      # code, redirect location, body size, and TLS/network errors.
      def http_probe(url, accept: 'text/html,application/xhtml+xml')
        uri  = URI.parse(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl      = (uri.scheme == 'https')
        http.open_timeout = REQUEST_TIMEOUT
        http.read_timeout = REQUEST_TIMEOUT
        configure_ssl(http) if http.use_ssl?

        req = Net::HTTP::Get.new(uri.request_uri)
        req['User-Agent'] = user_agent
        req['Accept']     = accept
        res = http.request(req)
        { url: url, status: res.code.to_i, bytes: res.body.to_s.bytesize,
          location: res['location'], body: res.body.to_s,
          # Who answered and what they said. Without these a blocked source
          # reports only "looks_blocked: true", which is not enough to tell a
          # WAF rule from a rate limit from an outage.
          server: res['server'], content_type: res['content-type'] }
      rescue StandardError => e
        { url: url, status: nil, error: "#{e.class}: #{e.message}" }
      end

      # Adapters override to explain a zero-discovery result (URLs hit, HTTP
      # status, link counts, block-page detection). Surfaced by the admin Test
      # action when discovered == 0.
      def diagnostics
        { note: 'no diagnostics implemented for this adapter' }
      end

      # Heuristic: does this body look like a bot-block / challenge page rather
      # than the real content?
      def looks_blocked?(body)
        body.to_s[0, 4000].match?(/captcha|access denied|are you (a )?human|just a moment|cloudflare|cf-browser-verification|request unsuccessful/i)
      end

      def absolute_url(href, base_uri)
        URI.join("#{base_uri.scheme}://#{base_uri.host}", href).to_s
      rescue StandardError
        href
      end

      def base_url
        source.base_url.to_s.sub(%r{/\z}, '')
      end

      # First non-blank attribute among `names` on a Nokogiri node.
      def first_attr(node, names)
        names.each do |n|
          v = node[n]
          return v if v.to_s.strip.present?
        end
        nil
      end

      def scan_regex(html, regex)
        return nil if html.blank?

        m = html.match(regex)
        m&.to_s
      end
    end
  end
end
