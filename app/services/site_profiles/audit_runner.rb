# frozen_string_literal: true

module SiteProfiles
  # Grades a site that was scanned before the audit existed, without rescanning.
  #
  # A demo already sent to a prospect must not be disturbed to get a report: a
  # rescan rewrites the profile's content, can shift what they have already been
  # shown, and rotating the link would break the URL in their inbox. The scan
  # already recorded which pages it read, so this re-fetches those and grades
  # them. Nothing about the demo itself changes except the report.
  #
  # Also the natural home for re-running an audit later, when a dealer has
  # acted on the findings and wants to see the score move.
  class AuditRunner
    # A handful of pages is enough to characterise a site, and this runs against
    # somebody else's server at their expense.
    MAX_PAGES = 10

    def initialize(profile, fetcher: Fetcher.new)
      @profile = profile
      @fetcher = fetcher
    end

    def call
      urls = page_urls
      return nil if urls.empty?

      pages = {}
      from_archive = false

      urls.each do |url|
        response = @fetcher.get(url)
        next if response.nil? || !response.html?

        pages[response.url] = response.body
        from_archive ||= response.try(:from_archive?).present?
      end

      return nil if pages.empty?

      report = SeoAudit.new(
        source_url: @profile.source_url.presence || urls.first,
        pages_html: pages,
        fetcher: @fetcher,
        from_archive: from_archive
      ).call

      @profile.update!(seo_report: report)
      report
    rescue StandardError => e
      Rails.logger.warn("[SiteProfiles::AuditRunner] #{@profile.id}: #{e.class}: #{e.message}")
      nil
    end

    private

    # The pages the scan actually read, so the audit grades the same site rather
    # than whatever a fresh crawl happens to find today.
    def page_urls
      stored = Array(@profile.report['pages_scanned']).select { |u| u.is_a?(String) && u.start_with?('http') }
      return stored.first(MAX_PAGES) if stored.any?

      # A document-sourced profile has no scanned pages, and neither does an
      # older record. The source URL alone still yields a usable grade.
      [@profile.source_url].compact_blank
    end
  end
end
