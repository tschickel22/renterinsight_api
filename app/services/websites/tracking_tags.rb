# frozen_string_literal: true

module Websites
  # Turns a site's tracking_config into the markup that actually fires.
  #
  # The typed fields have been collected for a long time and emitted nowhere:
  # permitted, entered in WebsiteForm and detected by the site scanner, but
  # nothing ever turned any of them into a script tag. A dealer who entered their GA4 ID got
  # a saved value and no analytics, with nothing to indicate why.
  #
  # Rendered server side, into the shell, for two reasons. A pixel that fires
  # only after React mounts misses the visitors who leave first, which on an ad
  # landing page is exactly the population being measured. And Meta's own
  # installation checks look at the delivered HTML.
  class TrackingTags
    Result = Struct.new(:head, :body, keyword_init: true)

    # Each of these is a well-known vendor whose snippet we can write
    # correctly from an id alone; anything else belongs in the custom
    # head/body fields, where the author owns the markup. The formats are
    # strict on purpose: an id goes into a script, so only the characters
    # its vendor uses get through.
    ID_FORMATS = {
      # Analytics
      'google_analytics_id'   => /\A(?:G-[A-Z0-9]{4,}|UA-\d{4,}-\d{1,4})\z/i,
      'google_tag_manager_id' => /\AGTM-[A-Z0-9]{4,}\z/i,
      # Advertising
      'google_ads_id'         => /\AAW-\d{6,12}\z/i,
      'facebook_pixel_id'     => /\A\d{8,20}\z/,
      'tiktok_pixel_id'       => /\A[A-Z0-9]{15,30}\z/i,
      'snapchat_pixel_id'     => /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/,
      'pinterest_tag_id'      => /\A\d{10,16}\z/,
      'linkedin_partner_id'   => /\A\d{4,10}\z/,
      'x_pixel_id'            => /\A[a-z0-9]{4,10}\z/i,
      'reddit_pixel_id'       => /\A[at]2_[a-z0-9]{4,20}\z/i,
      'microsoft_uet_tag_id'  => /\A\d{5,12}\z/,
      # Visitor behavior
      'hotjar_id'             => /\A\d{5,12}\z/,
      'microsoft_clarity_id'  => /\A[a-z0-9]{6,14}\z/i,
      'logrocket_app_id'      => %r{\A[a-z0-9]{4,10}/[a-z0-9_-]{1,60}\z}i
    }.freeze

    # What the website and landing page params permit, so a new vendor here
    # can't be dropped by a controller that was never told about it.
    FIELDS = ID_FORMATS.keys.freeze

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
      tags << tiktok_pixel
      tags << snapchat_pixel
      tags << pinterest_tag
      tags << linkedin_insight
      tags << x_pixel
      tags << reddit_pixel
      tags << microsoft_uet
      tags << hotjar
      tags << microsoft_clarity
      tags << logrocket
      tags << config.dig('custom_scripts', 'head')
      tags.compact
    end

    def body_markup
      [gtm_body, config.dig('custom_scripts', 'body')].compact
    end

    # GA4 and Google Ads share one Google tag: one loader, a config line each.
    # Two loaders would load gtag.js twice and set up dataLayer twice.
    def gtag
      ids = [id_for('google_analytics_id'), id_for('google_ads_id')].compact
      return nil if ids.empty?

      configs = ids.map { |id| "  gtag('config', '#{e(id)}');" }.join("\n")
      <<~HTML
        <script async src="https://www.googletagmanager.com/gtag/js?id=#{e(ids.first)}"></script>
        <script>
          window.dataLayer = window.dataLayer || [];
          function gtag(){dataLayer.push(arguments);}
          gtag('js', new Date());
        #{configs}
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

    def tiktok_pixel
      id = id_for('tiktok_pixel_id')
      return nil if id.nil?

      <<~HTML
        <script>
          !function (w, d, t) {
            w.TiktokAnalyticsObject=t;var ttq=w[t]=w[t]||[];ttq.methods=["page","track","identify","instances","debug","on","off","once","ready","alias","group","enableCookie","disableCookie","holdConsent","revokeConsent","grantConsent"],ttq.setAndDefer=function(t,e){t[e]=function(){t.push([e].concat(Array.prototype.slice.call(arguments,0)))}};for(var i=0;i<ttq.methods.length;i++)ttq.setAndDefer(ttq,ttq.methods[i]);ttq.instance=function(t){for(var e=ttq._i[t]||[],n=0;n<ttq.methods.length;n++)ttq.setAndDefer(e,ttq.methods[n]);return e},ttq.load=function(e,n){var r="https://analytics.tiktok.com/i18n/pixel/events.js",o=n&&n.partner;ttq._i=ttq._i||{},ttq._i[e]=[],ttq._i[e]._u=r,ttq._t=ttq._t||{},ttq._t[e]=+new Date,ttq._o=ttq._o||{},ttq._o[e]=n||{};n=document.createElement("script");n.type="text/javascript",n.async=!0,n.src=r+"?sdkid="+e+"&lib="+t;e=document.getElementsByTagName("script")[0];e.parentNode.insertBefore(n,e)};
            ttq.load('#{e(id)}');
            ttq.page();
          }(window, document, 'ttq');
        </script>
      HTML
    end

    def snapchat_pixel
      id = id_for('snapchat_pixel_id')
      return nil if id.nil?

      <<~HTML
        <script>
          (function(e,t,n){if(e.snaptr)return;var a=e.snaptr=function(){a.handleRequest?a.handleRequest.apply(a,arguments):a.queue.push(arguments)};
          a.queue=[];var s='script';var r=t.createElement(s);r.async=!0;r.src=n;var u=t.getElementsByTagName(s)[0];
          u.parentNode.insertBefore(r,u);})(window,document,'https://sc-static.net/scevent.min.js');
          snaptr('init', '#{e(id)}', {});
          snaptr('track', 'PAGE_VIEW');
        </script>
      HTML
    end

    def pinterest_tag
      id = id_for('pinterest_tag_id')
      return nil if id.nil?

      <<~HTML
        <script>
          !function(e){if(!window.pintrk){window.pintrk=function(){window.pintrk.queue.push(Array.prototype.slice.call(arguments))};var
          n=window.pintrk;n.queue=[],n.version="3.0";var t=document.createElement("script");t.async=!0,t.src=e;var
          r=document.getElementsByTagName("script")[0];r.parentNode.insertBefore(t,r)}}("https://s.pinimg.com/ct/core.js");
          pintrk('load', '#{e(id)}');
          pintrk('page');
        </script>
        <noscript><img height="1" width="1" style="display:none;" alt=""
          src="https://ct.pinterest.com/v3/?event=init&tid=#{e(id)}&noscript=1"/></noscript>
      HTML
    end

    def linkedin_insight
      id = id_for('linkedin_partner_id')
      return nil if id.nil?

      <<~HTML
        <script>
          _linkedin_partner_id = "#{e(id)}";
          window._linkedin_data_partner_ids = window._linkedin_data_partner_ids || [];
          window._linkedin_data_partner_ids.push(_linkedin_partner_id);
          (function(l){if(!l){window.lintrk=function(a,b){window.lintrk.q.push([a,b])};window.lintrk.q=[]}
          var s=document.getElementsByTagName("script")[0];var b=document.createElement("script");
          b.type="text/javascript";b.async=true;b.src="https://snap.licdn.com/li.lms-analytics/insight.min.js";
          s.parentNode.insertBefore(b,s);})(window.lintrk);
        </script>
        <noscript><img height="1" width="1" style="display:none;" alt=""
          src="https://px.ads.linkedin.com/collect/?pid=#{e(id)}&fmt=gif"/></noscript>
      HTML
    end

    def x_pixel
      id = id_for('x_pixel_id')
      return nil if id.nil?

      <<~HTML
        <script>
          !function(e,t,n,s,u,a){e.twq||(s=e.twq=function(){s.exe?s.exe.apply(s,arguments):s.queue.push(arguments);
          },s.version='1.1',s.queue=[],u=t.createElement(n),u.async=!0,u.src='https://static.ads-twitter.com/uwt.js',
          a=t.getElementsByTagName(n)[0],a.parentNode.insertBefore(u,a))}(window,document,'script');
          twq('config', '#{e(id)}');
        </script>
      HTML
    end

    def reddit_pixel
      id = id_for('reddit_pixel_id')
      return nil if id.nil?

      <<~HTML
        <script>
          !function(w,d){if(!w.rdt){var p=w.rdt=function(){p.sendEvent?p.sendEvent.apply(p,arguments):p.callQueue.push(arguments)};
          p.callQueue=[];var t=d.createElement("script");t.src="https://www.redditstatic.com/ads/pixel.js",t.async=!0;
          var s=d.getElementsByTagName("script")[0];s.parentNode.insertBefore(t,s)}}(window,document);
          rdt('init', '#{e(id)}');
          rdt('track', 'PageVisit');
        </script>
      HTML
    end

    # Microsoft Advertising (Bing) UET. enableAutoSpaTracking: the site is a
    # single-page app, and without it UET counts one page per visit.
    def microsoft_uet
      id = id_for('microsoft_uet_tag_id')
      return nil if id.nil?

      <<~HTML
        <script>
          (function(w,d,t,r,u){var f,n,i;w[u]=w[u]||[],f=function(){var o={ti:"#{e(id)}", enableAutoSpaTracking: true};
          o.q=w[u],w[u]=new UET(o),w[u].push("pageLoad")},n=d.createElement(t),n.src=r,n.async=1,
          n.onload=n.onreadystatechange=function(){var s=this.readyState;s&&s!=="loaded"&&s!=="complete"||(f(),
          n.onload=n.onreadystatechange=null)},i=d.getElementsByTagName(t)[0],i.parentNode.insertBefore(n,i)})
          (window,document,"script","//bat.bing.com/bat.js","uetq");
        </script>
      HTML
    end

    def microsoft_clarity
      id = id_for('microsoft_clarity_id')
      return nil if id.nil?

      <<~HTML
        <script>
          (function(c,l,a,r,i,t,y){c[a]=c[a]||function(){(c[a].q=c[a].q||[]).push(arguments)};
          t=l.createElement(r);t.async=1;t.src="https://www.clarity.ms/tag/"+i;
          y=l.getElementsByTagName(r)[0];y.parentNode.insertBefore(t,y);})(window, document, "clarity", "script", "#{e(id)}");
        </script>
      HTML
    end

    def logrocket
      id = id_for('logrocket_app_id')
      return nil if id.nil?

      <<~HTML
        <script src="https://cdn.lr-ingest.com/LogRocket.min.js" crossorigin="anonymous"></script>
        <script>window.LogRocket && window.LogRocket.init('#{e(id)}');</script>
      HTML
    end

    def e(value)
      ERB::Util.html_escape(value)
    end
  end
end
