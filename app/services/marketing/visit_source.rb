# frozen_string_literal: true

module Marketing
  # Where a visit came from, in one place.
  #
  # Extracted so the landing page report and the platform live view cannot give
  # two different answers about the same visit. They did not disagree yet; this
  # is here because the second caller is exactly when that starts.
  #
  # A tag wins over a referrer, because a tag says which ad and a referrer only
  # says which site.
  module VisitSource
    # Referrer hosts worth naming. Anything else is reported by its host, which
    # is more use than lumping it under "other".
    KNOWN = {
      /(^|\.)facebook\.com$/i => 'facebook',
      /(^|\.)instagram\.com$/i => 'instagram',
      /(^|\.)google\./i => 'google',
      /(^|\.)bing\.com$/i => 'bing',
      /(^|\.)linkedin\.com$/i => 'linkedin',
      /(^|\.)t\.co$/i => 'twitter',
      /(^|\.)youtube\.com$/i => 'youtube'
    }.freeze

    module_function

    # @param own_hosts [Enumerable<String>] hostnames the visited site answers
    #   on. A referrer pointing at one of them is a reload or an in-page link,
    #   not a source, and crediting it would have the page credit itself.
    def label(utm_source:, referrer:, own_hosts: [])
      return utm_source if utm_source.present?

      host = host_of(referrer)
      return 'direct' if host.blank?
      return 'direct' if own_hosts.include?(host)

      KNOWN.each { |pattern, name| return name if host.match?(pattern) }
      host
    end

    def host_of(referrer)
      return nil if referrer.blank?

      URI.parse(referrer).host&.downcase&.delete_prefix('www.')
    rescue URI::InvalidURIError
      nil
    end
  end
end
