# frozen_string_literal: true

module SiteProfiles
  # Walks the scripts, iframes and links across every scanned page and reports
  # which third-party services the site uses and what we intend to do with each.
  #
  # Anything third-party that we do not recognise is surfaced as 'unknown'
  # rather than dropped — a silently discarded widget is how a dealer's chat
  # box disappears without anyone noticing.
  class VendorDetector
    # Extracting IDs lets these land in typed tracking_config fields instead of
    # a script blob, which is what makes them editable in TrackingTagsPanel.
    ID_PATTERNS = {
      'google_tag_manager_id' => /\bGTM-[A-Z0-9]+\b/,
      'google_analytics_id' => /\bG-[A-Z0-9]+\b|\bUA-\d+-\d+\b/,
      'facebook_pixel_id' => /fbq\(\s*['"]init['"]\s*,\s*['"](\d{6,})['"]/,
      'hotjar_id' => /hjid\s*[:=]\s*(\d+)/
    }.freeze

    Detection = Struct.new(
      :vendor, :category, :disposition, :source, :url, :config_key, :value, :label,
      keyword_init: true
    )

    def initialize(digests, source_host: nil)
      @digests = Array(digests)
      @source_host = source_host
    end

    def call
      detections = []

      @digests.each do |digest|
        detections.concat(from_scripts(digest))
        detections.concat(from_iframes(digest))
        detections.concat(from_links(digest))
      end

      dedupe(detections)
    end

    private

    def from_scripts(digest)
      scripts = digest.scripts || {}
      results = []

      Array(scripts[:external] || scripts['external']).each do |src|
        sig = VendorSignatures.match(src)
        next unless sig

        results << build(sig, source: 'script', url: src, digest: digest)
      end

      # Inline bodies carry both the vendor signature and, usually, the ID.
      Array(scripts[:inline] || scripts['inline']).each do |body|
        sig = VendorSignatures.match(body)
        results << build(sig, source: 'inline_script', url: nil, digest: digest, body: body) if sig
      end

      results
    end

    def from_iframes(digest)
      Array(digest.iframes).filter_map do |src|
        sig = VendorSignatures.match(src)
        sig ? build(sig, source: 'iframe', url: src, digest: digest) : unknown_third_party(src, 'iframe')
      end
    end

    def from_links(digest)
      Array(digest.links).filter_map do |link|
        href = link[:href] || link['href']
        sig = VendorSignatures.match(href)
        next unless sig
        # Only destinations are interesting from links; a link to
        # googletagmanager.com is not the dealer's analytics setup.
        next unless sig.disposition == 'link_out'

        build(sig, source: 'link', url: href, digest: digest,
                   label: link[:label] || link['label'])
      end
    end

    def build(sig, source:, url:, digest:, body: nil, label: nil)
      config_key = sig.config_key
      value = config_key ? extract_id(config_key, body || url || '', digest) : nil

      Detection.new(
        vendor: sig.vendor,
        category: sig.category,
        disposition: sig.disposition,
        source: source,
        url: url,
        config_key: config_key,
        value: value,
        label: label
      )
    end

    # IDs frequently live in a different script than the loader, so fall back to
    # scanning every inline body on the page before giving up.
    def extract_id(config_key, text, digest)
      pattern = ID_PATTERNS[config_key]
      return nil unless pattern

      match = pattern.match(text)
      return (match[1] || match[0]) if match

      inline = digest.scripts&.[](:inline) || digest.scripts&.[]('inline') || []
      ([text] + Array(inline)).each do |candidate|
        m = pattern.match(candidate.to_s)
        return m[1] || m[0] if m
      end
      nil
    end

    def unknown_third_party(url, source)
      host = begin
        URI.parse(url).host
      rescue StandardError
        nil
      end
      return nil if host.blank?
      return nil if @source_host.present? && host.include?(@source_host.to_s)
      # Maps and video are ubiquitous furniture, not integrations to report.
      # Matched against the full URL, since "google.com/maps" is a path — a
      # host-only check never sees it.
      return nil if url.to_s.match?(
        %r{google\.com/maps|google\.com/maps/embed|youtube\.com|youtube-nocookie\.com|vimeo\.com|//player\.}i
      )

      Detection.new(vendor: host, category: 'unknown', disposition: 're_embed',
                    source: source, url: url)
    end

    def dedupe(detections)
      detections.compact.uniq { |d| [d.vendor, d.disposition, d.config_key, d.url] }
                .group_by { |d| [d.vendor, d.config_key] }
                .map { |_, group| group.find { |d| d.value.present? } || group.first }
    end
  end
end
