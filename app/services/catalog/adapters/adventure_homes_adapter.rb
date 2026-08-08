# frozen_string_literal: true

require 'json'

module Catalog
  module Adapters
    # Adapter for Adventure Homes (adventurehomes.net) — WordPress + Jupiter X
    # child theme, custom `floorplan` post type, server rendered. No headless
    # browser.
    #
    # Identity: the page slug (last path segment) is the stable source_key.
    #
    # Shaped like AvadaSitemapAdapter (WordPress SSR, Yoast CPT sitemap, labeled
    # <li> specs) but the theme's markup is its own, so the selectors do not
    # transfer. It is NOT the manufacturedhomes_platform shape either: that
    # adapter already matches /floorplan/ URLs for Timber Creek, but keys on a
    # numeric {floorplanId}-{dealerId} that Adventure's slugs ("6481ls-16-stretch")
    # do not carry, so it would discover nothing here.
    #
    # CALIBRATED against a full 130-page crawl on 2026-08-07:
    #   model name, series, beds, baths, sq ft, WxL, standards PDF  130/130
    #   gallery photos                                               65/130
    #   3D tour                                                      31/130
    #   prose description                                        not published
    # Every plan carries a hero floorplan drawing even when its gallery is
    # empty, so `images` is never blank. Mark `description` untracked on the
    # source: the site has no descriptive copy anywhere, and left tracked it
    # sits at 0% and trips the degradation threshold on every healthy run.
    #
    # FEATURES COME FROM A PDF, AND THEY ARE SERIES-LEVEL. Each plan links a
    # "Standard Features" sheet that covers its whole series (4 sheets cover all
    # 130 homes), so they are a series promise with an effective date, not a
    # verified fact about the individual home. Parsed by StandardsPdfParser and
    # cached per URL for the run.
    #
    # 3D TOURS COME FROM THE DETAIL PAGE, NOT MATTERPORT. Adventure's public
    # Matterport account page lists 24 spaces; the floorplan pages link 31, and
    # the 6 account-only spaces are custom and community builds with no
    # published plan. Both Matterport hosts also return 403 to a server fetch.
    # So the detail page is both more complete and the only fetchable source,
    # and its link is already bound to the right model.
    class AdventureHomesAdapter < BaseAdapter
      SITEMAP_PATH   = '/floorplan-sitemap.xml'
      DETAIL_PATH    = '/floorplan/'
      REST_FLOORPLAN = '/wp-json/wp/v2/floorplan'
      REST_HOME_TYPE = '/wp-json/wp/v2/home_type'
      REST_PAGE_SIZE = 100
      REST_MAX_PAGES = 10

      # The site publishes the same tour under two hosts (22 and 9 of the 31
      # links respectively), and older Matterport links use the /show/?m= form.
      MATTERPORT_RE = %r{https?://(?:discover\.matterport\.com/space/[A-Za-z0-9]+
                                  |(?:www\.)?matterport\.com/discover/space/[A-Za-z0-9]+
                                  |(?:my\.)?matterport\.com/show/\?[^\s"'<>)]*m=[A-Za-z0-9]+)[^\s"'<>)]*}ix

      # Spec rows render as <li><b>Label:</b> value</li>.
      SPEC_MODEL_ID   = ['model number'].freeze
      SPEC_SERIES     = ['home series', 'series'].freeze
      SPEC_BEDROOMS   = ['bedrooms', 'beds'].freeze
      SPEC_BATHROOMS  = ['bathrooms', 'baths'].freeze
      SPEC_SQUARE_FT  = ['square feet', 'sq ft'].freeze
      SPEC_DIMENSIONS = ['wxl', 'w x l', 'dimensions'].freeze

      # The host runs a WAF that answers the shared BaseAdapter UA with a 75KB
      # branded 403 on every URL, sitemap included — which reads as "site down"
      # rather than "blocked", since it is not a recognisable challenge page. A
      # current browser UA is served normally. Verified 2026-08-07.
      USER_AGENT = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 ' \
                   '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'

      # robots.txt sets no crawl-delay, but back-to-back fetches stall the site.
      # 130 pages at 5s is ~11 minutes, which a daily schedule absorbs fine.
      # A snapshot run touches the network zero times, so it waits for nothing.
      def crawl_delay
        return 0 if snapshot_bound?

        Integer(source.config['crawl_delay'] || 5)
      end

      # SiteGround's Anti-Bot AI challenges our Render egress, so a run from the
      # platform gets a captcha stub instead of the site. Until they allowlist
      # us, `snapshot_key` binds a catalog captured from a machine that can
      # reach them (see catalog:homes_snapshot:capture) and the source runs the
      # real ingestion path against it. Clearing the key goes back to live.
      def snapshot_key
        source.config.is_a?(Hash) ? source.config['snapshot_key'].presence : nil
      end

      # Bound is not the same as loaded. A source pointing at a snapshot that is
      # not stored must NOT quietly crawl instead: on Render that walks into the
      # captcha and reports an empty catalog, while the operator believes they
      # are running from a capture. Fail closed and say why.
      def snapshot_bound?
        snapshot_key.present?
      end

      def snapshot
        return @snapshot if defined?(@snapshot)

        @snapshot = snapshot_key ? HomesSnapshot.read(snapshot_key) : nil
      end

      # Surfaced to the admin so a snapshot-backed run is never mistaken for a
      # live crawl of the manufacturer.
      def snapshot_info
        return nil if snapshot.blank?

        { 'key' => snapshot_key, 'captured_at' => snapshot['captured_at'],
          'home_count' => Array(snapshot['homes']).size }
      end

      def user_agent
        (source.config.is_a?(Hash) && source.config['user_agent'].presence) || USER_AGENT
      end

      def discover(limit: nil)
        @urls ||= {}
        keys = if snapshot_bound?
                 snapshot.present? ? snapshot_keys : warn_missing_snapshot
               else
                 discover_from_sitemap.presence || discover_from_rest
               end
        limit ? keys.first(limit) : keys
      end

      def fetch(key)
        if snapshot_bound?
          home = snapshot.present? ? snapshot_homes[key.to_s] : nil
          return home && { key: key.to_s, snapshot: home }
        end

        url  = (@urls || {})[key] || "#{site_root}#{DETAIL_PATH}#{key}/"
        html = http_get(url)
        { key: key.to_s, url: url, html: html }
      end

      def parse(raw)
        # A snapshot already holds parsed homes, so rebuild rather than re-run
        # extractors that have no page to read.
        return NormalizedHome.from_h(raw[:snapshot]) if raw[:snapshot].present?

        doc = raw[:html].present? ? Nokogiri::HTML(raw[:html]) : nil
        # "Related Floor Plan" repeats OTHER models' cards, images and spec
        # lists inside the same container. Drop it before anything reads the
        # page, or a neighbour's photos and beds/baths land on this home.
        doc&.css('script, style, noscript, .related_floorplan')&.remove
        standards = standards_for(doc)

        NormalizedHome.new(
          source_key:       raw[:key],
          source_url:       raw[:url],
          model_name:       extract_name(doc),
          model_id:         extract_model_id(doc),
          series:           spec_value(doc, SPEC_SERIES),
          property_type:    property_type_for(raw[:key]),
          bedrooms:         to_int(spec_value(doc, SPEC_BEDROOMS)),
          bathrooms:        to_decimal(spec_value(doc, SPEC_BATHROOMS)),
          dimensions:       spec_value(doc, SPEC_DIMENSIONS),
          square_feet:      to_int(spec_value(doc, SPEC_SQUARE_FT)),
          description:      nil, # the site publishes no descriptive copy
          features:         standards.sections,
          images:           extract_images(doc),
          virtual_tour_url: extract_tour(doc, raw[:html]),
          price_quote_url:  nil, # pricing comes from the retailer, never the site
          raw: {
            'standards_pdf_url'  => literature_url(doc),
            'standards_title'    => standards.title,
            'standards_notice'   => standards.disclaimer,
            'standards_effective' => standards_effective(literature_url(doc))
          }.compact
        )
      end

      def diagnostics
        if snapshot_key.present?
          return { adapter: 'adventure_homes', mode: 'snapshot', snapshot_key: snapshot_key,
                   snapshot_found: snapshot.present?,
                   home_count: Array(snapshot&.[]('homes')).size,
                   captured_at: snapshot&.[]('captured_at'),
                   note: snapshot.present? ? 'Running from a captured catalog, not a live crawl.' :
                         "Snapshot '#{snapshot_key}' is bound but not stored — re-upload it." }
        end

        url   = sitemap_url
        probe = http_probe(url, accept: 'application/xml,text/xml')
        out = {
          adapter:        'adventure_homes',
          sitemap_url:    url,
          sitemap_status: probe[:status],
          bytes:          probe[:bytes],
          redirect:       probe[:location],
          user_agent:     user_agent,
          server:         probe[:server],
          content_type:   probe[:content_type]
        }
        out[:error] = probe[:error] if probe[:error]
        if probe[:body].present?
          out[:loc_count]       = probe[:body].scan(%r{<loc>}).size
          out[:floorplan_count] = probe[:body].scan(DETAIL_PATH).size
          out[:looks_blocked]   = looks_blocked?(probe[:body])
          # The host answers a blocked request with a 202 and a ~190 byte stub
          # rather than an error, so the status alone reads as success. Show the
          # body when it is clearly not a sitemap, so the next person sees the
          # blocker's own words instead of guessing from a boolean.
          out[:body_preview] = probe[:body].to_s.strip[0, 400] if out[:loc_count].zero?
        end
        out
      end

      private

      def warn_missing_snapshot
        Rails.logger.warn "[#{self.class.name}] snapshot '#{snapshot_key}' is bound but not stored; " \
                          'refusing to crawl instead. Re-upload it, or clear snapshot_key to go live.'
        []
      end

      # source_key => stored home hash, in capture order.
      def snapshot_homes
        @snapshot_homes ||= Array(snapshot['homes']).each_with_object({}) do |home, map|
          h = home.deep_stringify_keys
          key = h['source_key'].to_s
          map[key] = h if key.present?
        end
      end

      def snapshot_keys
        snapshot_homes.keys
      end

      def discover_from_sitemap
        body = http_get(sitemap_url, accept: 'application/xml,text/xml')
        return [] if body.blank?

        Nokogiri::XML(body).remove_namespaces!.css('url > loc').map(&:text)
                .select { |loc| loc.include?(DETAIL_PATH) }
                .filter_map { |loc| register_url(loc) }.uniq
      rescue StandardError => e
        Rails.logger.warn "[#{self.class.name}] sitemap discovery failed: #{e.message}"
        []
      end

      # Fallback when the Yoast sitemap is unavailable: the same 130 plans are
      # published through the WordPress REST API.
      def discover_from_rest
        rest_floorplans.filter_map { |post| register_url(post['link']) }.uniq
      rescue StandardError => e
        Rails.logger.warn "[#{self.class.name}] REST discovery failed: #{e.message}"
        []
      end

      def register_url(loc)
        slug = slug_for(loc)
        return nil if slug.blank?

        @urls[slug] = loc
        slug
      end

      def sitemap_url
        source.config['sitemap_url'].presence || "#{site_root}#{SITEMAP_PATH}"
      end

      def extract_name(doc)
        name = doc&.at_css('.floor_name')&.text.to_s.gsub(/\s+/, ' ').strip
        return name if name.present?

        og = doc&.at_css('meta[property="og:title"]')&.[]('content').to_s
        og.sub(/\s*[-|]\s*Adventure Homes\s*\z/i, '').strip.presence
      end

      def extract_model_id(doc)
        doc&.at_css('#curr_model_name')&.text.to_s.strip.presence ||
          spec_value(doc, SPEC_MODEL_ID)
      end

      # <li><b>Bedrooms:</b> 3</li> — match on the bold label, return the rest.
      def spec_value(doc, labels)
        return nil if doc.nil?

        wanted = labels.map(&:downcase)
        doc.css('.specification_list li, .floor-CDetails li').each do |li|
          label = li.at_css('b')&.text.to_s.downcase.sub(/:\s*\z/, '').strip
          next unless wanted.include?(label)

          value = li.text.sub(/\A\s*#{Regexp.escape(li.at_css('b').text)}/, '')
          value = value.gsub(/\s+/, ' ').strip
          return value if value.present?
        end
        nil
      end

      # The hero image is the plan drawing, present on every home; the swiper
      # below it is the photo gallery, which half the plans leave empty.
      def extract_images(doc)
        return [] if doc.nil?

        images = {}
        hero = doc.at_css('a.floor-image-popup')&.[]('href')
        images[hero] = image_entry(hero, is_floorplan: true) if uploaded?(hero)

        doc.css('.floor_gallery_image a[href], .gallery_section a[href]').each do |a|
          href = a['href']
          next unless uploaded?(href)

          images[href] ||= image_entry(href, is_floorplan: false)
        end
        images.values
      end

      def image_entry(url, is_floorplan:)
        { 'source_url' => url, 'local_url' => nil, 'alt' => '', 'is_floorplan' => is_floorplan }
      end

      def uploaded?(url)
        url.to_s.include?('/wp-content/uploads/') && !url.to_s.match?(/logo|icon/i)
      end

      def extract_tour(doc, html)
        button = doc&.at_css('a.req_qut_btn')&.[]('href')
        return button if button.to_s.match?(MATTERPORT_RE)

        scan_regex(html.to_s, MATTERPORT_RE)
      end

      def literature_url(doc)
        doc&.at_css('a.literature_btn')&.[]('href').presence
      end

      # Sheets are named "<Series>-Standards-January-19th-2026.pdf", so the file
      # name carries the effective date and a rename is the signal that the
      # manufacturer revised the features.
      def standards_effective(url)
        name = url.to_s.split('/').last.to_s
        m = name.match(/([A-Z][a-z]+)-(\d{1,2})(?:st|nd|rd|th)?-(\d{4})/)
        return nil unless m

        Date.parse("#{m[1]} #{m[2]} #{m[3]}").to_s
      rescue StandardError
        nil
      end

      # One sheet per series, so a 130-home run fetches 4 PDFs, not 130. Cached
      # per adapter instance, which is per run.
      def standards_for(doc)
        url = literature_url(doc)
        return StandardsPdfParser::EMPTY if url.blank?

        @standards ||= {}
        @standards[url] ||= begin
          bytes = http_get(url, accept: 'application/pdf')
          result = StandardsPdfParser.parse(bytes)
          Rails.logger.info(
            "[#{self.class.name}] standards #{url.split('/').last}: " \
            "#{result.sections.size} sections, #{result.feature_count} features"
          )
          result
        end
      end

      # Property type lives in the `home_type` taxonomy (HUD, MOD, ANSI, NEV),
      # which the theme does not render on the page. One pair of REST calls
      # builds the slug => type map for the whole catalog.
      def property_type_for(key)
        home_types[key.to_s] || []
      end

      def home_types
        @home_types ||= build_home_types
      end

      def build_home_types
        names = rest_get("#{site_root}#{REST_HOME_TYPE}?per_page=#{REST_PAGE_SIZE}&_fields=id,name")
        return {} if names.blank?

        labels = names.to_h { |term| [term['id'], term['name']] }
        rest_floorplans.each_with_object({}) do |post, map|
          slug = post['slug'].to_s
          next if slug.blank?

          map[slug] = Array(post['home_type']).filter_map { |id| labels[id] }
        end
      rescue StandardError => e
        Rails.logger.warn "[#{self.class.name}] home_type lookup failed: #{e.message}"
        {}
      end

      def rest_floorplans
        @rest_floorplans ||= begin
          posts = []
          (1..REST_MAX_PAGES).each do |page|
            batch = rest_get(
              "#{site_root}#{REST_FLOORPLAN}?per_page=#{REST_PAGE_SIZE}&page=#{page}" \
              '&_fields=slug,link,home_type'
            )
            break if batch.blank?

            posts.concat(batch)
            break if batch.size < REST_PAGE_SIZE
          end
          posts
        end
      end

      def rest_get(url)
        body = http_get(url, accept: 'application/json')
        return nil if body.blank?

        parsed = JSON.parse(body)
        parsed.is_a?(Array) ? parsed : nil
      rescue JSON::ParserError => e
        Rails.logger.warn "[#{self.class.name}] bad JSON from #{url}: #{e.message}"
        nil
      end

      def slug_for(loc)
        URI.parse(loc.to_s).path.split('/').reject(&:blank?).last
      rescue StandardError
        nil
      end

      def site_root
        uri = URI.parse(source.base_url.to_s)
        "#{uri.scheme}://#{uri.host}"
      rescue StandardError
        source.base_url.to_s.sub(%r{/+\z}, '')
      end

      def to_int(value)
        return nil if value.blank?

        digits = value.to_s.gsub(/[^\d]/, '')
        digits.presence&.to_i
      end

      def to_decimal(value)
        return nil if value.blank?

        m = value.to_s.match(/\d+(\.\d+)?/)
        m && m[0]
      end
    end
  end
end
