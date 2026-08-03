# frozen_string_literal: true

require 'net/http'
require 'uri'

module Catalog
  # Polite HTTP GET for catalog crawling, mirroring BaseAdapter#http_get: browser
  # UA, timeouts, follows redirects, returns nil rather than raising so one bad
  # page never sinks a crawl.
  #
  # Extracted from NextFlightPayload, which is where it used to live. Nothing
  # about fetching a page is specific to Next.js RSC payloads, and directory
  # services for plain server-rendered sites need it without inheriting a module
  # whose name promises flight-payload parsing.
  #
  # Per-site crawl rights are the caller's responsibility, not this module's.
  module PoliteHttp
    USER_AGENT = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' \
                 '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
    HTTP_TIMEOUT = 30

    module_function

    def http_get(url, accept: 'text/html,application/xhtml+xml', redirects: 3)
      uri  = URI.parse(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl      = (uri.scheme == 'https')
      http.open_timeout = HTTP_TIMEOUT
      http.read_timeout = HTTP_TIMEOUT

      req = Net::HTTP::Get.new(uri.request_uri)
      req['User-Agent'] = USER_AGENT
      req['Accept']     = accept
      res = http.request(req)

      case res
      when Net::HTTPSuccess then res.body
      when Net::HTTPRedirection
        loc = res['location']
        return nil if loc.blank? || redirects <= 0

        http_get(URI.join(url, loc).to_s, accept: accept, redirects: redirects - 1)
      else
        Rails.logger.warn "[Catalog::PoliteHttp] HTTP #{res.code} for #{url}"
        nil
      end
    rescue StandardError => e
      Rails.logger.warn "[Catalog::PoliteHttp] HTTP error for #{url}: #{e.class}: #{e.message}"
      nil
    end
  end
end
