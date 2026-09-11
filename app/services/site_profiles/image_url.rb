# frozen_string_literal: true

module SiteProfiles
  # The picture, not the thumbnail the page happened to lay out.
  #
  # A hero taken from a page is stretched across the full width of ours, so a
  # 600px file arrives visibly soft beside the client's own site. Measured on
  # thehomeplus.com: every <img> carries ?width=600 for a 1600x1000 original,
  # and the demo's hero was 600x375 against their sharp full-size one.
  #
  # Lived inside PageDigest, which meant it only ever ran on images found in the
  # body of a page. The logo comes from BrandExtractor and never passed through
  # it, so every scanned logo was whatever size the client's header asked for:
  # thehomeplus.com's arrived 188x96 from a 531x271 original, and looked exactly
  # as soft as that sounds in a header that shows it larger than they do.
  #
  # Two shapes to undo, and only these two , anything not recognised is left
  # exactly as it was, because a URL we do not understand is one we can only
  # break.
  module ImageUrl
    SIZE_PARAMS = %w[w width h height q quality dpr size].freeze

    module_function

    def full_size(url)
      uri = URI.parse(url)
      return url if uri.query.blank?

      params = URI.decode_www_form(uri.query)

      # Next.js serves everything through /_next/image?url=<original>&w=640,
      # so the original is sitting right there in the query string.
      inner = params.find { |key, _| key == 'url' }&.last if uri.path.include?('/_next/image')
      return full_size(URI.join(url, inner).to_s) if inner.present?

      # Crop and format are deliberate framing, kept. Only the size knobs go:
      # dropping them is what the CDN treats as "give me the original".
      kept = params.reject { |key, _| SIZE_PARAMS.include?(key.downcase) }
      return url if kept.size == params.size

      uri.query = kept.any? ? URI.encode_www_form(kept) : nil
      uri.to_s
    rescue StandardError
      url
    end
  end
end
