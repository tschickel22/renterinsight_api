# frozen_string_literal: true

module SiteProfiles
  # Host/pattern -> vendor lookup for third-party embeds.
  #
  # Deliberately a table, not an AI call. "Which chat widget is this?" is a
  # question with a finite, knowable answer set; asking a model is slower, costs
  # money, and is wrong more often than a regex on a script host.
  #
  # DISPOSITIONS
  #   native    - we have our own; replace it (their contact form -> our block)
  #   re_embed  - client keeps their vendor; goes to custom_scripts.head/body
  #   mapped    - maps onto a first-class tracking_config field, not a blob
  #   link_out  - a destination, not a script; becomes a CTA
  #   drop      - superseded by us (their old inventory widget)
  module VendorSignatures
    Signature = Struct.new(:vendor, :category, :disposition, :pattern, :config_key, keyword_init: true)

    # Builds a host-anchored pattern. A bare /homes\.com/ also matches
    # championhomes.com, which would silently drop a manufacturer link as if it
    # were a competitor's inventory widget. Require the domain to start a host:
    # preceded by "//" or "." and followed by a port, path, or end of string.
    def self.host(*domains)
      alternation = domains.map { |d| Regexp.escape(d) }.join('|')
      %r{(?://|\.)(?:#{alternation})(?:[:/?#]|\z)}i
    end

    SIGNATURES = [
      # --- analytics / pixels: we have typed fields for these ---
      # GA4 is served from googletagmanager.com too, so match its gtag/js path
      # FIRST — a bare /googletagmanager\.com/ here would shadow it, since
      # VendorSignatures.match returns the first hit.
      Signature.new(vendor: 'Google Analytics', category: 'analytics', disposition: 'mapped',
                    pattern: %r{google-analytics\.com|gtag/js}i, config_key: 'google_analytics_id'),
      Signature.new(vendor: 'Google Tag Manager', category: 'analytics', disposition: 'mapped',
                    pattern: %r{googletagmanager\.com/(gtm\.js|ns\.html)|\bGTM-[A-Z0-9]+\b}i,
                    config_key: 'google_tag_manager_id'),
      Signature.new(vendor: 'Meta Pixel', category: 'analytics', disposition: 'mapped',
                    pattern: %r{(?://|\.)connect\.facebook\.net|fbevents\.js|fbq\(}i, config_key: 'facebook_pixel_id'),
      Signature.new(vendor: 'Hotjar', category: 'analytics', disposition: 'mapped',
                    pattern: host('static.hotjar.com', 'hotjar.com', 'hotjar.io'), config_key: 'hotjar_id'),

      # --- chat / messaging: keep the client's own vendor ---
      Signature.new(vendor: 'Intercom', category: 'chat', disposition: 're_embed',
                    pattern: host('widget.intercom.io', 'intercomcdn.com')),
      Signature.new(vendor: 'Drift', category: 'chat', disposition: 're_embed',
                    pattern: host('js.driftt.com', 'driftt.com', 'drift.com')),
      Signature.new(vendor: 'Tawk.to', category: 'chat', disposition: 're_embed',
                    pattern: host('embed.tawk.to', 'tawk.to')),
      Signature.new(vendor: 'Podium', category: 'chat', disposition: 're_embed',
                    pattern: host('widget.podium.com', 'podium.com')),
      Signature.new(vendor: 'Crisp', category: 'chat', disposition: 're_embed',
                    pattern: host('client.crisp.chat', 'crisp.chat')),
      Signature.new(vendor: 'Tidio', category: 'chat', disposition: 're_embed',
                    pattern: host('code.tidio.co', 'tidio.co')),
      Signature.new(vendor: 'LiveChat', category: 'chat', disposition: 're_embed',
                    pattern: host('cdn.livechatinc.com', 'livechatinc.com')),
      Signature.new(vendor: 'Birdeye', category: 'chat', disposition: 're_embed',
                    pattern: host('birdeye.com')),

      # --- financing / pre-approval: destinations, so they become CTAs ---
      Signature.new(vendor: '700Credit', category: 'financing', disposition: 'link_out',
                    pattern: host('700credit.com')),
      Signature.new(vendor: 'RouteOne', category: 'financing', disposition: 'link_out',
                    pattern: host('routeone.net', 'routeone.com')),
      Signature.new(vendor: 'Dealertrack', category: 'financing', disposition: 'link_out',
                    pattern: host('dealertrack.com')),
      Signature.new(vendor: '21st Mortgage', category: 'financing', disposition: 'link_out',
                    pattern: host('21stmortgage.com')),
      Signature.new(vendor: 'Triad Financial', category: 'financing', disposition: 'link_out',
                    pattern: host('triadfs.com')),
      Signature.new(vendor: 'Octane Lending', category: 'financing', disposition: 'link_out',
                    pattern: host('octanelending.com', 'octane.co')),
      Signature.new(vendor: 'Vanderbilt Mortgage', category: 'financing', disposition: 'link_out',
                    pattern: host('vmf.com', 'vanderbiltmortgage.com')),

      # --- scheduling ---
      Signature.new(vendor: 'Calendly', category: 'scheduling', disposition: 're_embed',
                    pattern: host('assets.calendly.com', 'calendly.com')),
      Signature.new(vendor: 'HubSpot', category: 'marketing', disposition: 're_embed',
                    pattern: host('js.hs-scripts.com', 'hs-analytics.net')),

      # --- inventory: superseded by our own block ---
      Signature.new(vendor: 'MHVillage', category: 'inventory', disposition: 'drop',
                    pattern: host('mhvillage.com')),
      Signature.new(vendor: 'RVTrader', category: 'inventory', disposition: 'drop',
                    pattern: host('rvtrader.com')),
      Signature.new(vendor: 'HomesDirect', category: 'inventory', disposition: 'drop',
                    pattern: host('homesdirect365.com', 'homes.com'))
    ].freeze

    module_function

    def match(url)
      return nil if url.blank?

      SIGNATURES.find { |sig| sig.pattern.match?(url.to_s) }
    end

    def all
      SIGNATURES
    end
  end
end
