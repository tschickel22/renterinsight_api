# frozen_string_literal: true

module SiteProfiles
  # Splits the site's links into the two things a rebuild needs:
  #
  #   internal - which pages exist, and what belongs in nav/footer
  #   external - destinations we must preserve, WITH the anchor text that says
  #              what each one was for. A bare lender URL tells us nothing;
  #              "Get Pre-Approved in 60 Seconds" tells us exactly where that
  #              CTA belongs. Without the context they become footer orphans.
  class LinkInventory
    # Maps a path onto the role it plays, so projection knows which template
    # slot each page corresponds to.
    ROLE_PATTERNS = {
      'home' => %r{\A/?\z|\A/(home|index)}i,
      'inventory' => /inventory|homes|listings|floor-?plans|models|for-sale/i,
      'financing' => /financ|credit|loan|pre-?approv|apply|payment/i,
      'about' => /about|our-story|who-we-are|team|staff/i,
      'contact' => /contact|locations?|visit|directions|hours/i,
      'services' => /service|parts|warranty|support|maintenance/i,
      'land' => /land|lots?|communit|parks?/i,
      'blog' => /blog|news|articles|resources/i,
      'gallery' => /gallery|photos|tour/i,
      'faq' => /faq|questions/i
    }.freeze

    SKIP_EXTENSIONS = /\.(pdf|jpe?g|png|gif|svg|zip|docx?|xlsx?|mp4|webm)\z/i

    def initialize(digests, base_url:)
      @digests = Array(digests)
      @base_host = safe_host(base_url)
    end

    def call
      internal = {}
      external = {}

      @digests.each do |digest|
        Array(digest.links).each do |link|
          href = link[:href] || link['href']
          label = (link[:label] || link['label']).to_s.squish
          next if href.blank?

          uri = safe_parse(href)
          next if uri.nil? || uri.path.to_s.match?(SKIP_EXTENSIONS)

          if internal?(uri)
            path = normalize_path(uri.path)
            next if path.blank?

            entry = internal[path] ||= { 'path' => path, 'label' => label.presence, 'page_role' => role_for(path, label) }
            entry['label'] ||= label.presence
          else
            key = href
            entry = external[key] ||= {
              'href' => href,
              'label' => label.presence,
              'category' => external_category(href, label),
              'context' => label.presence
            }
            entry['label'] ||= label.presence
          end
        end
      end

      {
        'internal' => internal.values.sort_by { |e| e['path'] },
        'external' => external.values
      }
    end

    private

    def internal?(uri)
      uri.host.blank? || (@base_host.present? && uri.host == @base_host)
    end

    def normalize_path(path)
      p = path.to_s.split('?').first.to_s
      p = "/#{p}" unless p.start_with?('/')
      p = p.chomp('/') unless p == '/'
      p.presence || '/'
    end

    def role_for(path, label)
      haystack = "#{path} #{label}"
      ROLE_PATTERNS.each do |role, pattern|
        return role if role == 'home' ? path.match?(pattern) : haystack.match?(pattern)
      end
      'other'
    end

    def external_category(href, label)
      sig = VendorSignatures.match(href)
      return sig.category if sig

      haystack = "#{href} #{label}"
      return 'social' if href.match?(/facebook|instagram|twitter|x\.com|linkedin|youtube|tiktok|pinterest/i)
      return 'financing' if haystack.match?(/financ|credit|loan|pre-?approv|apply/i)
      return 'manufacturer' if haystack.match?(/champion|cavco|clayton|skyline|fleetwood|palm-?harbor|homes-?of-?merit/i)
      return 'reviews' if haystack.match?(/review|yelp|bbb\.org|trustpilot|google\.com\/maps/i)

      'other'
    end

    def safe_parse(href)
      URI.parse(href)
    rescue URI::InvalidURIError
      nil
    end

    def safe_host(url)
      URI.parse(url.to_s).host
    rescue URI::InvalidURIError
      nil
    end
  end
end
