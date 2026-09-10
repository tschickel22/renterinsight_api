# frozen_string_literal: true

require 'net/http'
require 'json'

module SiteProfiles
  # Loads a page in a real browser when a plain fetch cannot read it.
  #
  # Two kinds of site defeat Net::HTTP, and both are common among the competitor
  # builds we are most often asked to scan:
  #
  #   1. A bot wall. Vercel's Attack Challenge Mode answers every request with
  #      HTTP 429 and a "Security Checkpoint" page until the client runs a small
  #      JavaScript proof-of-work and keeps the cookie it sets. Any browser
  #      clears it in about two seconds; nothing without a JS engine ever does.
  #      Measured on thehomeplus.com: 429 to curl with every header a browser
  #      sends, 368 words and 28 internal links to Chrome.
  #   2. A client-rendered site. The HTML is an empty shell and the content
  #      arrives from JavaScript, so we scanned a page that says nothing. The
  #      digest already flags these (likely_client_rendered?); until now the only
  #      answer was to note it in the warnings.
  #
  # This is not CAPTCHA solving and does not pretend to be a person: it is a
  # browser loading a public marketing page, once, at the request of the admin
  # building that dealer a demo, with robots.txt still consulted and the same
  # ten-page budget as before.
  #
  # Off unless configured.
  #
  #   SITE_SCAN_RENDERER      chrome | browserless | scrapingbee   (absent = off)
  #   SITE_SCAN_RENDER_URL    browserless only, e.g. https://chrome.example.com
  #   SITE_SCAN_RENDER_TOKEN  the hosted providers' API key
  #
  # 'chrome' is headless Chrome in this container , see LocalBrowser. It is what
  # ten to twenty scans a month deserve: no subscription, no third party holding
  # a prospect's page, and no per-render cost. The hosted providers stay here
  # for the day that volume changes, or if Chrome proves too heavy to sit beside
  # Puma.
  class Renderer
    class << self
      def provider
        ENV['SITE_SCAN_RENDERER'].to_s.strip.downcase.presence
      end

      def enabled?
        case provider
        when 'chrome' then true
        when 'browserless', 'scrapingbee' then ENV['SITE_SCAN_RENDER_TOKEN'].present?
        else false
        end
      end
    end

    # Rendering is slow by nature — a browser start, a navigation and a network
    # settle. Well beyond Fetcher's 15s read timeout, and still bounded so one
    # unresponsive site cannot hold a scan open indefinitely.
    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 45
    MAX_BODY_BYTES = 5 * 1024 * 1024

    def initialize(logger: Rails.logger)
      @logger = logger
    end

    # @return [String, nil] rendered HTML, or nil when rendering is off, the
    #   provider failed, or it returned something that is not a page. Every
    #   caller treats nil as "carry on with what you had".
    def call(url)
      return nil unless self.class.enabled?
      return local_browser.render(url) if self.class.provider == 'chrome'

      response = post_or_get(url)
      return nil unless response.is_a?(Net::HTTPSuccess)

      html = truncate(response.body)
      return nil if html.blank?

      # A provider that hands back the challenge page has not rendered anything
      # useful, and passing it on would put an interstitial into the profile.
      return nil if ArchiveFallback.challenged?(200, html)

      html
    rescue StandardError => e
      @logger.warn("[SiteProfiles::Renderer] #{url}: #{e.class}: #{e.message}")
      nil
    end

    # Ends the browser session, if this renderer started one. Called once a scan
    # is finished; the hosted providers hold no session and ignore it.
    def close
      @local_browser&.close
      @local_browser = nil
    end

    private

    def local_browser
      @local_browser ||= LocalBrowser.new(logger: @logger)
    end

    def post_or_get(url)
      case self.class.provider
      when 'browserless' then browserless(url)
      when 'scrapingbee' then scrapingbee(url)
      end
    end

    # POST /content returns the DOM after the page has settled, which is the
    # whole point: the challenge has been cleared and the client-rendered markup
    # exists by then.
    def browserless(url)
      base = ENV['SITE_SCAN_RENDER_URL'].presence || 'https://production-sfo.browserless.io'
      endpoint = URI.join(base, '/content')
      endpoint.query = URI.encode_www_form(token: ENV['SITE_SCAN_RENDER_TOKEN'])

      request = Net::HTTP::Post.new(endpoint)
      request['Content-Type'] = 'application/json'
      request.body = {
        url: url,
        # networkidle2 rather than load: the challenge redirects to the real
        # page after its check, and `load` fires on the checkpoint.
        gotoOptions: { waitUntil: 'networkidle2', timeout: 30_000 }
      }.to_json

      perform(endpoint, request)
    end

    def scrapingbee(url)
      endpoint = URI.parse('https://app.scrapingbee.com/api/v1/')
      endpoint.query = URI.encode_www_form(
        api_key: ENV['SITE_SCAN_RENDER_TOKEN'], url: url, render_js: 'true'
      )

      perform(endpoint, Net::HTTP::Get.new(endpoint))
    end

    def perform(uri, request)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      http.request(request)
    end

    def truncate(body)
      return '' if body.nil?

      body = body.byteslice(0, MAX_BODY_BYTES) if body.bytesize > MAX_BODY_BYTES
      body.dup.force_encoding(Encoding::UTF_8).scrub('')
    end
  end
end
