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
        when 'browserless', 'scrapingbee' then hosted_configured?
        else false
        end
      end

      # A hosted renderer can be configured alongside local Chrome, as the
      # answer to the one thing our own browser cannot fix: a check that refuses
      # this server's address rather than its browser. Their egress is not a
      # Render IP, so the page opens.
      #
      # Only reached when local Chrome has already failed on a challenge, so a
      # site that reads normally never costs a credit.
      def hosted_fallback
        return nil unless hosted_configured?

        ENV['SITE_SCAN_HOSTED_RENDERER'].to_s.strip.downcase.presence ||
          (%w[browserless scrapingbee].include?(provider) ? provider : 'browserless')
      end

      def hosted_configured?
        ENV['SITE_SCAN_RENDER_TOKEN'].present?
      end
    end

    # Rendering is slow by nature — a browser start, a navigation and a network
    # settle. Well beyond Fetcher's 15s read timeout, and still bounded so one
    # unresponsive site cannot hold a scan open indefinitely.
    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 45
    MAX_BODY_BYTES = 5 * 1024 * 1024

    # Why the last render did or did not produce a page. Carried out to the
    # failure message, because "no readable content" on its own cannot tell a
    # browser that never started from a bot check that never cleared, and those
    # want opposite fixes.
    OUTCOMES = %i[rendered still_challenged empty unavailable error off].freeze

    attr_reader :last_outcome

    # Free-text detail from the last attempt, when there is any: how long the
    # wait was and which Chromium ran it. Quoted in the failure message, because
    # "the check refused us" and "the check needed longer than we waited" read
    # identically without it.
    attr_reader :last_detail

    def initialize(logger: Rails.logger)
      @logger = logger
      @last_outcome = nil
      @last_detail = nil
    end

    # @return [String, nil] rendered HTML, or nil when rendering is off, the
    #   provider failed, or it returned something that is not a page. Every
    #   caller treats nil as "carry on with what you had".
    def call(url)
      return record(:off, nil) unless self.class.enabled?

      html = if self.class.provider == 'chrome'
               browser = local_browser
               rendered = browser.render(url)
               return record(:unavailable, nil) unless browser.available?

               if still_challenged?(rendered)
                 # Our own browser could not get past the wall. If a hosted
                 # renderer is configured, this is exactly what it is for.
                 # Failing that, report the wall rather than an empty result:
                 # they are different problems and only one of them is ours.
                 walled = rendered.present?
                 hosted = hosted_retry(url)
                 return record(walled ? :still_challenged : :empty, nil) if hosted.blank?

                 hosted
               else
                 rendered
               end
             else
               hosted_html(url, self.class.provider)
             end

      return record(:empty, nil) if html.blank?

      # A render that hands back the challenge page has produced nothing useful,
      # and passing it on would put an interstitial into the profile — which is
      # precisely the bug this class exists to prevent. Applies to a browser of
      # our own exactly as it does to a hosted one: this check used to sit after
      # an early return for chrome, so a checkpoint that never cleared was
      # treated as a successful render.
      return record(:still_challenged, nil) if ArchiveFallback.challenged?(200, html)

      record(:rendered, html)
    rescue StandardError => e
      @logger.warn("[SiteProfiles::Renderer] #{url}: #{e.class}: #{e.message}")
      record(:error, nil)
    end

    # Ends the browser session, if this renderer started one. Called once a scan
    # is finished; the hosted providers hold no session and ignore it.
    def close
      @local_browser&.close
      @local_browser = nil
    end

    private

    def still_challenged?(html)
      html.blank? || ArchiveFallback.challenged?(200, html)
    end

    def hosted_retry(url)
      provider = self.class.hosted_fallback
      return nil if provider.nil?

      @logger.info("[SiteProfiles::Renderer] #{url} still walled after local Chrome; trying #{provider}")
      @used_hosted = true
      hosted_html(url, provider)
    end

    def hosted_html(url, provider)
      response = post_or_get(url, provider)
      return nil unless response.is_a?(Net::HTTPSuccess)

      truncate(response.body)
    end

    def record(outcome, html)
      @last_outcome = outcome
      @last_detail = [@local_browser&.diagnostic, (@used_hosted ? 'hosted renderer also tried' : nil)]
                     .compact.join('; ').presence
      html
    end

    def local_browser
      @local_browser ||= LocalBrowser.new(logger: @logger)
    end

    def post_or_get(url, provider = self.class.provider)
      case provider
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
      body = {
        url: url,
        # networkidle2 rather than load: the challenge redirects to the real
        # page after its check, and `load` fires on the checkpoint.
        gotoOptions: { waitUntil: 'networkidle2', timeout: 30_000 }
      }
      # Same reasoning as ScrapingBee's premium proxy: without residential
      # egress a hosted browser is refused exactly as ours is.
      body[:proxy] = 'residential' if premium_proxy?
      request.body = body.to_json

      perform(endpoint, request)
    end

    def scrapingbee(url)
      params = { api_key: ENV['SITE_SCAN_RENDER_TOKEN'], url: url, render_js: 'true' }
      # Residential egress, at a much higher credit cost per call.
      #
      # Not a nicety for the sites this exists for. A hosted renderer on a plain
      # datacenter address meets the same wall our own browser does — measured
      # on thehomeplus.com, which clears in 0.1s from a home connection and
      # never in 120s from Render, with the same browser build. Paying for
      # rendering without paying for the egress buys nothing here.
      params[:premium_proxy] = 'true' if premium_proxy?
      endpoint = URI.parse('https://app.scrapingbee.com/api/v1/')
      endpoint.query = URI.encode_www_form(params)

      perform(endpoint, Net::HTTP::Get.new(endpoint))
    end

    def premium_proxy?
      ActiveModel::Type::Boolean.new.cast(ENV.fetch('SITE_SCAN_RENDER_PREMIUM', 'true'))
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
