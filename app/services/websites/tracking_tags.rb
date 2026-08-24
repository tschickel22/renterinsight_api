# frozen_string_literal: true

module Websites
  # Turns a site's tracking_config into the markup that actually fires.
  #
  # The typed fields have been collected for a long time and emitted nowhere.
  # websites_controller permits google_analytics_id, google_tag_manager_id,
  # facebook_pixel_id and hotjar_id, WebsiteForm has inputs for all four, and
  # the site scanner detects them on an imported design — but nothing ever
  # turned any of them into a script tag. A dealer who entered their GA4 ID got
  # a saved value and no analytics, with nothing to indicate why.
  #
  # Rendered server side, into the shell, for two reasons. A pixel that fires
  # only after React mounts misses the visitors who leave first, which on an ad
  # landing page is exactly the population being measured. And Meta's own
  # installation checks look at the delivered HTML.
  class TrackingTags
    Result = Struct.new(:head, :body, keyword_init: true)

    # Deliberately narrow. Each of these is a well-known vendor whose snippet we
    # can write correctly from an id alone; anything else belongs in the custom
    # head/body fields, where the author owns the markup.
    ID_FORMATS = {
      'google_analytics_id'   => /\A(?:G-[A-Z0-9]{4,}|UA-\d{4,}-\d{1,4})\z/i,
      'google_tag_manager_id' => /\AGTM-[A-Z0-9]{4,}\z/i,
      'facebook_pixel_id'     => /\A\d{8,20}\z/,
      'hotjar_id'             => /\A\d{5,12}\z/
    }.freeze

    # @param website [Website]
    # @param page [WebsitePage, nil] the page being served, when it carries its own
    def initialize(website:, page: nil)
      @website = website
      @page = page
    end

    # Marks the document as already carrying these tags.
    #
    # SiteRenderer injects the custom head/body fields client side, which is
    # still right for the builder preview and a shared demo, where nothing
    # rendered this. On a live site both would now run and every snippet would
    # fire twice — two PageView events per visit, which is worse than none
    # because it looks like traffic.
    MARKER = '<meta name="dt-tracking" content="server">'

    def call
      head = head_markup.join("\n").presence
      head = "#{MARKER}\n#{head}" if head

      Result.new(head: head, body: body_markup.join("\n").presence)
    end

    # Site config with the page's merged over it.
    #
    # A scalar id set on the page wins, because that is what setting it on the
    # page means. Custom scripts CONCATENATE rather than override: the common
    # arrangement is one site-wide container plus a per-campaign pixel, and
    # making the page's snippet replace the site's would silently switch off
    # analytics for the page most in need of it.
    def merged_config
      site = stringify(@website&.tracking_config)
      page = stringify(@page&.try(:tracking_config))

      merged = site.merge(page.reject { |_, v| v.blank? })
      merged['custom_scripts'] = {
        'head' => join_scripts(site.dig('custom_scripts', 'head'), page.dig('custom_scripts', 'head')),
        'body' => join_scripts(site.dig('custom_scripts', 'body'), page.dig('custom_scripts', 'body'))
      }
      merged
    end

    private

    def stringify(value)
      value.is_a?(Hash) ? value.deep_stringify_keys : {}
    end

    def join_scripts(*parts)
      parts.map { |p| p.to_s.strip }.reject(&:empty?).join("\n").presence
    end

    def config
      @config ||= merged_config
    end

    # An id that does not match its vendor's shape is a typo, and emitting a
    # snippet around it produces a silent no-op plus a console error rather than
    # a clue. Skipped so the rest still fires.
    def id_for(key)
      value = config[key].to_s.strip
      return nil if value.blank?
      return nil unless ID_FORMATS.fetch(key).match?(value)

      value
    end

    def head_markup
      tags = []
      tags << gtm_head
      tags << gtag
      tags << facebook_pixel
      tags << hotjar
      tags << config.dig('custom_scripts', 'head')
      tags.compact
    end

    def body_markup
      [gtm_body, config.dig('custom_scripts', 'body')].compact
    end

    def gtag
      id = id_for('google_analytics_id')
      return nil if id.nil?

      <<~HTML
        <script async src="https://www.googletagmanager.com/gtag/js?id=#{ERB::Util.html_escape(id)}"></script>
        <script>
          window.dataLayer = window.dataLayer || [];
          function gtag(){dataLayer.push(arguments);}
          gtag('js', new Date());
          gtag('config', '#{ERB::Util.html_escape(id)}');
        </script>
      HTML
    end

    def gtm_head
      id = id_for('google_tag_manager_id')
      return nil if id.nil?

      <<~HTML
        <script>(function(w,d,s,l,i){w[l]=w[l]||[];w[l].push({'gtm.start':
        new Date().getTime(),event:'gtm.js'});var f=d.getElementsByTagName(s)[0],
        j=d.createElement(s),dl=l!='dataLayer'?'&l='+l:'';j.async=true;j.src=
        'https://www.googletagmanager.com/gtm.js?id='+i+dl;f.parentNode.insertBefore(j,f);
        })(window,document,'script','dataLayer','#{ERB::Util.html_escape(id)}');</script>
      HTML
    end

    # GTM's noscript half. Pointless for a visitor running JavaScript and
    # required by Google's own install instructions, so it goes in rather than
    # being judged.
    def gtm_body
      id = id_for('google_tag_manager_id')
      return nil if id.nil?

      %(<noscript><iframe src="https://www.googletagmanager.com/ns.html?id=#{ERB::Util.html_escape(id)}" ) +
        %(height="0" width="0" style="display:none;visibility:hidden"></iframe></noscript>)
    end

    def facebook_pixel
      id = id_for('facebook_pixel_id')
      return nil if id.nil?

      <<~HTML
        <script>
          !function(f,b,e,v,n,t,s){if(f.fbq)return;n=f.fbq=function(){n.callMethod?
          n.callMethod.apply(n,arguments):n.queue.push(arguments)};if(!f._fbq)f._fbq=n;
          n.push=n;n.loaded=!0;n.version='2.0';n.queue=[];t=b.createElement(e);t.async=!0;
          t.src=v;s=b.getElementsByTagName(e)[0];s.parentNode.insertBefore(t,s)}(window,
          document,'script','https://connect.facebook.net/en_US/fbevents.js');
          fbq('init', '#{ERB::Util.html_escape(id)}');
          fbq('track', 'PageView');
        </script>
        <noscript><img height="1" width="1" style="display:none"
          src="https://www.facebook.com/tr?id=#{ERB::Util.html_escape(id)}&ev=PageView&noscript=1"/></noscript>
      HTML
    end

    def hotjar
      id = id_for('hotjar_id')
      return nil if id.nil?

      <<~HTML
        <script>
          (function(h,o,t,j,a,r){h.hj=h.hj||function(){(h.hj.q=h.hj.q||[]).push(arguments)};
          h._hjSettings={hjid:#{ERB::Util.html_escape(id)},hjsv:6};a=o.getElementsByTagName('head')[0];
          r=o.createElement('script');r.async=1;
          r.src=t+h._hjSettings.hjid+j+h._hjSettings.hjsv;a.appendChild(r);
          })(window,document,'https://static.hotjar.com/c/hotjar-','.js?sv=');
        </script>
      HTML
    end
  end
end
