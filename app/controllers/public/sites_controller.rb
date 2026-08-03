# frozen_string_literal: true

module Public
  # Serves a tenant's website on the tenant's own hostname.
  #
  # Rails answers here rather than the SPA host because Cloudflare for SaaS forwards the
  # visitor's original Host header, and because search engines need the title, description,
  # canonical and Open Graph tags present in the first response. A single-page app cannot
  # set those early enough to be reliable.
  #
  # The page body still comes from the existing React renderer. There is deliberately no
  # server-side reimplementation of its 28 block types: several are interactive and the rest
  # would drift from the editor preview the first time either side changed. When prerendered
  # HTML exists for a page it is used instead, which is the upgrade path to fully static
  # pages without changing anything here.
  class SitesController < ActionController::Base
    skip_before_action :verify_authenticity_token

    # Dealer site traffic is public visitor traffic, and at scale it will dwarf API
    # traffic. Without these headers every page view reaches Rails, and the origin has to
    # be scaled to handle a load that is almost entirely identical repeated responses.
    #
    # Browsers hold a page briefly; Cloudflare holds it longer and, once stale, serves the
    # stale copy while fetching a fresh one behind it. So a dealer publishing a change is
    # visible within minutes, no visitor ever waits on our origin, and the origin sees a
    # trickle rather than the full firehose.
    BROWSER_MAX_AGE = 1.minute.to_i
    EDGE_MAX_AGE = 5.minutes.to_i
    # Was a day. The page references content-hashed asset filenames, so serving a stale copy
    # after a frontend deploy points visitors at assets that no longer exist and the page
    # renders blank. A day of that is not a trade worth making for origin protection, and
    # revalidating every couple of minutes still absorbs almost all traffic.
    STALE_WHILE_REVALIDATE = 2.minutes.to_i
    CRAWLER_FILE_EDGE_MAX_AGE = 1.hour.to_i

    before_action :resolve_site
    before_action :enforce_canonical_host
    after_action :strip_session_cookie

    def show
      html = prerendered_body || spa_shell
      return render_unavailable if html.nil?

      # Conditional GET. Cloudflare and browsers revalidate with the ETag once the cached
      # copy goes stale, so an unchanged page costs a 304 instead of a full render.
      return if stale_check_passes?

      cache_publicly(EDGE_MAX_AGE)
      render html: inject_head(html).html_safe, content_type: 'text/html' # rubocop:disable Rails/OutputSafety
    end

    # GET /robots.txt on a tenant hostname.
    #
    # Served per site rather than from a static file: an unpublished or noindex site must
    # not invite crawlers, and the sitemap line has to point at the dealer's own host.
    def robots
      cache_publicly(CRAWLER_FILE_EDGE_MAX_AGE)

      if @metadata[:robots].to_s.start_with?('noindex')
        return render plain: "User-agent: *\nDisallow: /\n", content_type: 'text/plain'
      end

      body = <<~ROBOTS
        User-agent: *
        Allow: /

        Sitemap: https://#{@canonical_host}/sitemap.xml
      ROBOTS

      render plain: body, content_type: 'text/plain'
    end

    def sitemap
      cache_publicly(CRAWLER_FILE_EDGE_MAX_AGE)
      pages = visible_pages

      xml = +%(<?xml version="1.0" encoding="UTF-8"?>\n)
      xml << %(<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n)
      pages.each do |page|
        xml << "  <url>\n"
        xml << "    <loc>#{ERB::Util.html_escape(page_url(page))}</loc>\n"
        xml << "    <lastmod>#{(page.updated_at || @website.updated_at).to_date.iso8601}</lastmod>\n"
        xml << "  </url>\n"
      end
      xml << "</urlset>\n"

      render xml: xml, content_type: 'application/xml'
    end

    private

    def cache_publicly(edge_max_age)
      response.headers['Cache-Control'] =
        "public, max-age=#{BROWSER_MAX_AGE}, s-maxage=#{edge_max_age}, " \
        "stale-while-revalidate=#{STALE_WHILE_REVALIDATE}"
    end

    # Rails sets a session cookie on any response that touches the session, and a response
    # carrying Set-Cookie is treated as private: Cloudflare will not cache it. These pages
    # are wholly public and stateless, so the cookie has no purpose and its presence would
    # silently disable edge caching entirely.
    def strip_session_cookie
      response.headers.delete('Set-Cookie')
    end

    # Changes whenever the site, the page, or the frontend bundle changes, so a publish is
    # picked up on the next revalidation rather than waiting for the TTL to lapse.
    #
    # The records go in whole rather than their updated_at values: a bare Time renders at
    # second precision inside a cache key, so two edits in the same second produced an
    # identical ETag and the stale copy stayed served. Rails builds a record's cache key at
    # microsecond precision.
    def cache_subject
      [@website, @page, Websites::SpaShell.version].compact
    end

    # A strong ETag, and deliberately no Last-Modified.
    #
    # This pairing is what took dealer sites down, so both halves matter:
    #
    # `etag:` produces a WEAK validator (W/"..."), and Cloudflare strips weak ETags on every
    # plan below Enterprise. The response reached the browser carrying only Last-Modified.
    #
    # Last-Modified can only describe the site record, and a frontend deploy changes the
    # page without touching it. So a browser holding a copy from before a deploy revalidated
    # with If-Modified-Since, got a 304, and kept reusing HTML that pointed at a bundle which
    # no longer existed. Permanently: every subsequent revalidation 304'd too. That is a
    # blank dealer site that no amount of reloading fixes.
    #
    # The ETag covers the shell version, so it does change on a frontend deploy. Making it
    # strong is what lets it survive Cloudflare and actually be used.
    def stale_check_passes?
      !stale?(strong_etag: cache_subject, public: true)
    end

    def resolve_site
      # Not request.host: dealer traffic arrives through a Worker that rewrites Host so
      # Render will accept it, carrying the real hostname in a verified header.
      @resolution = Websites::HostResolver.call(Websites::RequestHost.for(request))
      return render_not_found if @resolution.nil?

      @website = @resolution.website
      @canonical_host = @resolution.canonical_host
      @page = find_page
      @metadata = Websites::PageMetadata.new(
        website: @website, page: @page, canonical_host: @canonical_host
      ).to_h
    end

    # Applies the domain's force_ssl / force_www / redirect_type settings.
    #
    # These were stored and shown in Company Settings but read by nothing, so the toggles
    # saved a value and changed no behaviour. Now that Rails serves tenant sites it can
    # honour them directly, which is also better for the dealer than leaving both spellings
    # of their domain live: duplicate content splits search ranking between them.
    #
    # 301 rather than 302 so search engines consolidate on the canonical host.
    def enforce_canonical_host
      target = canonical_redirect_target
      return if target.nil?

      redirect_to target, status: :moved_permanently, allow_other_host: true
    end

    # Host only. force_ssl is deliberately NOT enforced here: Cloudflare terminates TLS and
    # forwards to the origin over http, so a scheme redirect in Rails would fire on every
    # request that Cloudflare already served over HTTPS, producing an infinite loop. HTTPS
    # is Cloudflare's job and it already does it.
    def canonical_redirect_target
      domain = @resolution&.company_domain
      return nil if domain.nil?

      host = Websites::RequestHost.for(request)
      wanted_host = canonical_host_for(domain, host)
      return nil if wanted_host == host

      "#{request.scheme}://#{wanted_host}#{request.fullpath}"
    end

    def canonical_host_for(domain, host)
      # force_www predates redirect_type and means the same thing as non_www_to_www. The
      # explicit selector wins; the older flag only applies when no selector is set.
      rule = domain.redirect_type.presence
      rule = domain.force_www ? 'non_www_to_www' : 'none' if rule.blank? || rule == 'none'

      case rule
      when 'non_www_to_www' then host.start_with?('www.') ? host : "www.#{host}"
      when 'www_to_non_www' then host.delete_prefix('www.')
      else host
      end
    end

    def find_page
      path = normalized_path
      pages = @website.website_pages.where(is_deleted: [false, nil])

      pages.find_by(path: path) ||
        pages.find_by(path: path.delete_prefix('/')) ||
        (path == '/' ? pages.order(:order).first : nil)
    end

    def normalized_path
      path = request.path.presence || '/'
      path = path.chomp('/') if path.length > 1
      path.presence || '/'
    end

    # Every page that exists, because every page that exists is reachable: find_page routes
    # by path and only excludes deleted pages, so a page left out of here was live and simply
    # undiscoverable.
    #
    # is_visible used to filter this. It was set by templates, written by no UI, and also
    # read as a nav veto, so pages ended up orphaned from the header, the footer and the
    # sitemap at once with no way for a dealer to change any of it. Placement is now
    # show_in_nav / show_in_footer, and listing is simply existence. Keeping a specific page
    # out of search is a per-page robots concern, which is a separate thing this never was.
    def visible_pages
      @website.website_pages
              .where(is_deleted: [false, nil])
              .order(:order)
    end

    def page_url(page)
      path = page.path.to_s
      path = "/#{path}" unless path.start_with?('/')
      path = '' if path == '/'
      "https://#{@canonical_host}#{path}"
    end

    # Seam for prerendered static HTML. Nothing writes this yet; when a publish-time
    # prerender step exists it stores HTML here and these pages become fully static with no
    # change to routing, resolution or metadata.
    def prerendered_body
      return nil if @page.nil?
      return nil unless @page.respond_to?(:prerendered_html)

      @page.prerendered_html.presence
    end

    def spa_shell
      Websites::SpaShell.fetch
    rescue Websites::SpaShell::ShellUnavailable => e
      Rails.logger.error("[Public::Sites] #{request.host}: #{e.message}")
      nil
    end

    # Replaces the shell's own title and injects the tags a crawler reads. Existing title
    # and description tags are removed first so the document does not end up with two.
    def inject_head(html)
      doc = html.sub(%r{<title>.*?</title>}im, '')
                .sub(%r{<meta\s+name=["']description["'][^>]*>}i, '')

      # The recovery script goes first, ahead of every asset tag in the document. A module
      # script that 404s can fire its error event while the parser is still working through
      # the head, so a listener registered at the end of the head would miss it and fall
      # back to the slow timeout.
      doc = doc.sub(%r{<head([^>]*)>}i) do
        "<head#{Regexp.last_match(1)}>\n#{stale_shell_recovery_tag}\n#{head_tags}"
      end

      # Before the app's own scripts, so the payload exists by the time it boots and it
      # never has to render an empty frame first.
      doc.sub(%r{</head>}i) { "#{site_payload_tag}\n</head>" }
    end

    # Recovers a page whose cached copy points at a bundle that no longer exists.
    #
    # The shell references content-hashed asset filenames. A frontend deploy makes the
    # previous ones 404, the host serves index.html in their place, and the browser refuses
    # an HTML response for a module script — leaving a dealer with a blank page. Short TTLs
    # narrow that window but cannot close it: the response was cached before the deploy.
    #
    # location.reload() is not enough on its own, and that is why the first version of this
    # did not work. A reload revalidates at best and is usually served straight from the
    # browser's own copy, so it returns the same dead HTML, the guard below then marks the
    # attempt as spent, and the visitor is left on the blank page for good. Recovery has to
    # request a URL neither the browser nor Cloudflare has seen, which is what the
    # cache-busting parameter is for.
    #
    # Two triggers: an asset that fails to load fires immediately, and a four second check
    # catches the case where the scripts loaded but nothing mounted. One attempt only,
    # tracked in sessionStorage, so a genuinely broken deploy renders nothing rather than
    # reloading forever.
    #
    # The parameter is stripped once the app mounts, so it never reaches a shared link or a
    # crawler's canonical URL.
    RECOVERY_PARAM = '__dt_reload'

    def stale_shell_recovery_tag
      <<~SCRIPT.html_safe # rubocop:disable Rails/OutputSafety
        <script>
        (function () {
          var KEY = 'dt-shell-retry';
          var PARAM = '#{RECOVERY_PARAM}';

          function mounted() {
            var root = document.getElementById('root');
            return !!root && root.childElementCount > 0;
          }

          function recover() {
            if (sessionStorage.getItem(KEY)) return;
            sessionStorage.setItem(KEY, '1');
            var url = new URL(window.location.href);
            url.searchParams.set(PARAM, Date.now().toString(36));
            window.location.replace(url.toString());
          }

          // An asset 404 comes back as index.html, which the browser rejects as a module
          // script. That error does not bubble, so the listener has to capture.
          //
          // Restricted to the app's own bundle. A dealer's tracking pixel or an ad blocker
          // killing a third-party script is not a stale shell, and reloading the page over
          // it would be a self-inflicted outage on a site that was rendering fine.
          window.addEventListener('error', function (e) {
            var el = e.target;
            if (!el || (el.tagName !== 'SCRIPT' && el.tagName !== 'LINK')) return;
            var src = el.src || el.href || '';
            if (src.indexOf('/assets/') === -1) return;
            if (mounted()) return;
            recover();
          }, true);

          window.addEventListener('load', function () {
            setTimeout(function () {
              if (mounted()) {
                sessionStorage.removeItem(KEY);
                var url = new URL(window.location.href);
                if (url.searchParams.has(PARAM)) {
                  url.searchParams.delete(PARAM);
                  window.history.replaceState({}, '', url.pathname + url.search + url.hash);
                }
                return;
              }
              recover();
            }, 4000);
          });
        })();
        </script>
      SCRIPT
    end

    # The site's content, embedded so the app can render it without a second round trip and
    # without needing to know how to resolve a hostname. Rails has already done that
    # resolution; repeating it client-side would be a second code path to keep in step.
    #
    # JSON inside a script tag, so "</script>" appearing in any dealer's copy cannot end the
    # tag early and inject markup. The forward slash escape is what prevents that.
    def site_payload_tag
      json = Websites::PublicPayload.for(@website).to_json
      # Cannot close the script tag early, whatever a dealer wrote in their copy.
      json = json.gsub('</', '<\\/')
      # Valid inside JSON strings, but a literal line break in JavaScript source.
      json = json.gsub("\u2028", '\\u2028').gsub("\u2029", '\\u2029')

      %(<script id="dealertide-site" type="application/json">#{json}</script>)
    rescue StandardError => e
      # A missing payload costs the rendered body, not the page: the head tags a crawler
      # reads are already correct.
      Rails.logger.error("[Public::Sites] payload build failed for #{@website&.id}: #{e.message}")
      ''
    end

    def head_tags
      tags = []
      tags << tag(:title, @metadata[:title])
      tags << meta_tag('description', @metadata[:description])
      tags << meta_tag('robots', @metadata[:robots])
      tags << link_tag('canonical', @metadata[:canonical_url])
      tags << link_tag('icon', @metadata[:favicon_url])
      tags << property_tag('og:title', @metadata[:title])
      tags << property_tag('og:description', @metadata[:description])
      tags << property_tag('og:url', @metadata[:canonical_url])
      tags << property_tag('og:type', @metadata[:og_type])
      tags << property_tag('og:site_name', @metadata[:site_name])
      tags << property_tag('og:image', @metadata[:og_image])
      tags << meta_tag('twitter:card', @metadata[:og_image].present? ? 'summary_large_image' : 'summary')
      tags.compact.join("\n")
    end

    def tag(name, value)
      return nil if value.blank?

      "<#{name}>#{ERB::Util.html_escape(value)}</#{name}>"
    end

    def meta_tag(name, value)
      return nil if value.blank?

      %(<meta name="#{name}" content="#{ERB::Util.html_escape(value)}">)
    end

    def property_tag(property, value)
      return nil if value.blank?

      %(<meta property="#{property}" content="#{ERB::Util.html_escape(value)}">)
    end

    def link_tag(rel, href)
      return nil if href.blank?

      %(<link rel="#{rel}" href="#{ERB::Util.html_escape(href)}">)
    end

    # Errors are never cached. A site that is briefly unreachable, or one whose domain was
    # just wired up, must not have that failure pinned at the edge for minutes afterwards.
    def render_not_found
      response.headers['Cache-Control'] = 'no-store'
      render plain: 'Site not found', status: :not_found
    end

    def render_unavailable
      response.headers['Cache-Control'] = 'no-store'
      render plain: 'Site temporarily unavailable', status: :service_unavailable
    end
  end
end
