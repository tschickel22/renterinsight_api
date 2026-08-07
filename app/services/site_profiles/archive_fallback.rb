# frozen_string_literal: true

module SiteProfiles
  # Retrieves a page from the Wayback Machine when the live site refuses us.
  #
  # Competitor-built sites increasingly sit behind a bot wall. Measured on a
  # Trove site (vhvisionhomes.com): every path, including /robots.txt, answers
  # HTTP 429 with `x-vercel-mitigated: challenge` and a "Vercel Security
  # Checkpoint" body. Cloudflare's equivalent returns 403 or a "Just a moment"
  # interstitial. Without a way past that, scanning a prospect on one of those
  # platforms yields nothing: no demo, and no gap report to show them either.
  # Those are exactly the prospects worth having a report about.
  #
  # An archived copy is a legitimate answer here rather than a workaround. We are
  # reading a public page a public archive already holds, at the same rate any
  # reader would, instead of trying to defeat the challenge. The trade is
  # staleness, so every response carries archived_at and callers disclose it.
  #
  # Nothing here retries or hammers. One CDX lookup, one fetch, then give up.
  class ArchiveFallback
    CDX_ENDPOINT = 'http://web.archive.org/cdx/search/cdx'

    # Statuses a bot wall answers with. 429 is the Vercel case, 403 Cloudflare's,
    # and 503 is what several appliance vendors return while "checking your
    # browser".
    BLOCKED_STATUSES = [403, 429, 503].freeze

    # A challenge that returns HTTP 200 is the nastier variant, because the scan
    # would otherwise treat the interstitial as the site's actual content and
    # build a demo out of it.
    CHALLENGE_SIGNATURES = [
      'vercel security checkpoint',
      'just a moment',
      'attention required',
      'checking your browser',
      'enable javascript and cookies to continue',
      'ddos protection by'
    ].freeze

    class << self
      # @param status [Integer]
      # @param body [String]
      def challenged?(status, body)
        return true if BLOCKED_STATUSES.include?(status.to_i)

        head = body.to_s[0, 4000].downcase
        return false if head.blank?

        CHALLENGE_SIGNATURES.any? { |sig| head.include?(sig) }
      end
    end

    def initialize(fetcher:, logger: Rails.logger)
      @fetcher = fetcher
      @logger = logger
    end

    # @return [Fetcher::Response, nil] the archived page, or nil when the
    #   archive has never seen this URL
    def call(url)
      snapshot = latest_snapshot(url)
      return nil if snapshot.nil?

      timestamp, original = snapshot

      # `id_` asks for the bytes as archived rather than the archive's rewritten
      # copy, which is what keeps <head>, canonical tags and JSON-LD intact. The
      # rewritten version mangles URLs and would make every canonical check wrong.
      archived_url = "https://web.archive.org/web/#{timestamp}id_/#{original}"

      # allow_archive: false, or a failure to reach the archive would recurse
      # back into the archive.
      response = @fetcher.get(archived_url, allow_archive: false)
      return nil if response.nil?

      Fetcher::Response.new(
        url: original,
        status: response.status,
        body: response.body,
        content_type: response.content_type,
        from_archive: true,
        archived_at: parse_timestamp(timestamp)
      )
    rescue StandardError => e
      @logger.warn("[SiteProfiles::ArchiveFallback] #{url}: #{e.class}: #{e.message}")
      nil
    end

    private

    # Most recent successful capture. Asking for one row sorted descending keeps
    # this to a single request no matter how heavily archived the site is.
    def latest_snapshot(url)
      query = URI.encode_www_form(
        url: url.to_s.sub(%r{\Ahttps?://}, ''),
        output: 'json',
        limit: -1,
        filter: 'statuscode:200',
        fl: 'timestamp,original'
      )

      response = @fetcher.get("#{CDX_ENDPOINT}?#{query}", allow_archive: false)
      return nil if response.nil? || response.body.blank?

      rows = JSON.parse(response.body)
      # Row 0 is the header, so anything shorter than two rows is a miss.
      return nil if rows.length < 2

      rows.last
    rescue JSON::ParserError
      nil
    end

    def parse_timestamp(stamp)
      Time.strptime(stamp.to_s, '%Y%m%d%H%M%S').utc
    rescue StandardError
      nil
    end
  end
end
