# frozen_string_literal: true

require 'net/http'

module SiteProfiles
  # Fetches pages from a third-party site under strict limits.
  #
  # Redirects are followed manually rather than by Net::HTTP so that every hop
  # goes back through UrlGuard — following redirects automatically would let a
  # public URL bounce us onto an internal address.
  class Fetcher
    class FetchError < StandardError; end

    MAX_REDIRECTS = 5
    MAX_BODY_BYTES = 5 * 1024 * 1024 # 5 MB
    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 15
    USER_AGENT = 'DealerTideSiteImporter/1.0 (+https://dealertide.com/bot)'

    # from_archive/archived_at travel with the body because a page read from the
    # Wayback Machine is still usable but is no longer necessarily current, and
    # anything shown to a prospect has to say so.
    Response = Struct.new(:url, :status, :body, :content_type, :from_archive, :archived_at,
                          keyword_init: true) do
      def html?
        content_type.to_s.include?('html')
      end

      def from_archive?
        from_archive.present?
      end
    end

    def initialize(logger: Rails.logger)
      @logger = logger
    end

    # Returns a Response, or nil when the page could not be fetched. Callers
    # treat a nil page as "skip and warn", never as a fatal error — one bad
    # page must not kill a whole scan.
    # allow_archive is false when fetching FROM the archive, so a failure there
    # cannot recurse back into it.
    def get(url, redirects_left: MAX_REDIRECTS, allow_archive: true)
      uri, = UrlGuard.validate!(url)

      response = perform(uri)
      body = response.is_a?(Net::HTTPSuccess) ? truncate(response.body) : ''
      status = response.code.to_i

      # A bot wall can answer 403/429 or, worse, 200 with an interstitial that
      # would otherwise be scanned as if it were the site's own content.
      if allow_archive && ArchiveFallback.challenged?(status, body)
        @logger.info("[SiteProfiles::Fetcher] #{url} challenged (HTTP #{status}); trying the archive")
        archived = ArchiveFallback.new(fetcher: self, logger: @logger).call(uri.to_s)
        return archived if archived
      end

      case response
      when Net::HTTPRedirection
        return nil if redirects_left <= 0

        location = response['location']
        return nil if location.blank?

        get(URI.join(uri, location).to_s, redirects_left: redirects_left - 1,
                                          allow_archive: allow_archive)
      when Net::HTTPSuccess
        Response.new(
          url: uri.to_s,
          status: status,
          body: body,
          content_type: response['content-type']
        )
      end
    rescue UrlGuard::BlockedUrlError
      raise
    rescue StandardError => e
      @logger.warn("[SiteProfiles::Fetcher] #{url} failed: #{e.class}: #{e.message}")
      nil
    end

    # robots.txt is advisory for us (we are scanning at the site owner's
    # request) but we record and honour it rather than assume consent.
    def robots_allows?(url, path = '/')
      uri, = UrlGuard.validate!(url)
      robots = get(URI.join("#{uri.scheme}://#{uri.host}:#{uri.port}", '/robots.txt').to_s)
      return true if robots.nil? || robots.body.blank?

      RobotsPolicy.new(robots.body).allows?(path)
    rescue StandardError
      true
    end

    private

    def perform(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT

      request = Net::HTTP::Get.new(uri)
      request['User-Agent'] = USER_AGENT
      request['Accept'] = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'

      http.request(request)
    end

    # Net::HTTP hands back ASCII-8BIT, which explodes the moment it is joined
    # with UTF-8 text elsewhere in the pipeline. Normalise once, here, rather
    # than at every consumer.
    def truncate(body)
      return '' if body.nil?

      body = body.byteslice(0, MAX_BODY_BYTES) if body.bytesize > MAX_BODY_BYTES
      body.dup.force_encoding(Encoding::UTF_8).scrub('')
    end
  end

  # Minimal robots.txt reader: only the rules that apply to everyone or to us.
  class RobotsPolicy
    def initialize(text)
      @disallowed = []
      applies = false

      text.to_s.each_line do |line|
        line = line.split('#').first.to_s.strip
        next if line.empty?

        key, value = line.split(':', 2).map { |s| s.to_s.strip }
        case key.downcase
        when 'user-agent'
          applies = ['*', 'dealertidesiteimporter'].include?(value.downcase)
        when 'disallow'
          @disallowed << value if applies && value.present?
        end
      end
    end

    def allows?(path)
      @disallowed.none? { |rule| path.start_with?(rule) }
    end
  end
end
