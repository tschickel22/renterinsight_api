# frozen_string_literal: true

module SiteProfiles
  # The same findings, told two ways.
  #
  # The audit exists to win the business, not to improve the incumbent's work.
  # A prospect handed a list of pages and precise remediation forwards it to
  # whoever built their site, that agency fixes it for free, and the reason to
  # switch evaporates. We would have paid to make a competitor look responsive.
  #
  # So the client sees WHAT is wrong and WHY IT COSTS THEM, and we keep WHERE.
  # Category, severity and counts are persuasive and honest: "six pages have no
  # meta description" is a real finding that stands up in a meeting. The page
  # addresses and the fix-shaped detail are the part that only has value to
  # somebody doing the work, so they stay internal.
  #
  # Internal keeps everything, because a rep needs the specifics to speak
  # credibly, and once we win we have to actually fix them.
  module SeoReportView
    # Kept out of the client view: these read as instructions rather than
    # consequences.
    CLIENT_DROP_KEYS = %w[urls weight].freeze

    module_function

    def internal(report)
      report.presence&.deep_stringify_keys
    end

    # @return [Hash, nil] findings with the addresses and the how removed
    def client(report)
      data = report.presence&.deep_stringify_keys
      return nil if data.blank?

      data.merge(
        'checks' => Array(data['checks']).map { |check| client_check(check) },
        # Named so the reader knows this is a summary rather than the whole
        # picture, and so nobody on our side mistakes it for the full report.
        'audience' => 'client'
      ).except('pages_scanned')
    end

    def client_check(check)
      check.except(*CLIENT_DROP_KEYS).merge(
        # A count without the addresses: still concrete, still checkable by the
        # dealer against their own site, but not a work order.
        'affected_count' => Array(check['urls']).size
      )
    end
  end
end
