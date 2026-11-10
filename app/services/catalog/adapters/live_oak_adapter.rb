# frozen_string_literal: true

require 'json'
require 'digest'

module Catalog
  module Adapters
    # Adapter for Live Oak Manufactured Homes (liveoakmanufacturedhomes.com):
    # WordPress + Divi, homes are the theme's `project` post type. No headless
    # browser.
    #
    # Identity: the page slug is the stable source_key. It does not always
    # resemble the model name (Bolt is "runner-singlewide", Gunner is
    # "runner-28x64"), so the name comes from the post title, never the slug.
    #
    # Two sources per home, because neither carries everything:
    #   REST /wp/v2/project   name, category terms, featured photo (one fetch)
    #   the rendered page     gallery and Matterport tour (REST holds raw Divi
    #                         shortcodes with attachment ids, not image URLs)
    #
    # Everything structured comes from one taxonomy, project_category, which
    # mixes bedroom count, section width, series and merchandising labels.
    #
    # THE SITE PUBLISHES NO BATHS, SQUARE FEET, DIMENSIONS, MODEL NUMBERS,
    # DESCRIPTIONS OR FLOOR PLANS. Measured across all 101 homes on 2026-11-02:
    # none in page text, REST content or the media library. Never infer them
    # here: a guessed bath count on a dealer listing is worse than a blank.
    #
    # They come instead from Live Oak's own floor plan sheets, read once into
    # db/catalog_specs/live_oak.json (keyed by slug) with the plan images in the
    # public catalog bucket. That covers 93 of the 101 homes as of 2026-11-10;
    # the rest stay blank, which is why the fields remain untracked on the
    # source (ADAPTER_CONFIG_DEFAULTS). A new home on the site gets no specs
    # until its sheet is added to that file.
    class LiveOakAdapter < BaseAdapter
      REST_PROJECTS  = '/wp-json/wp/v2/project'
      REST_PAGE_SIZE = 100
      REST_MAX_PAGES = 10
      REST_FIELDS    = 'slug,link,title,_links,_embedded'
      REST_EMBED     = 'wp:featuredmedia,wp:term'

      TAXONOMY    = 'project_category'
      BEDROOMS_RE = /\A(\d+)\s*Bedroom/i
      WIDTH_RE    = /\A(?:single|double|triple)wide\z/i
      # Terms that describe how a home is merchandised, not which series it is.
      NON_SERIES_TERMS = ['featured', 'porch model'].freeze

      SPEC_SHEET = Rails.root.join('db/catalog_specs/live_oak.json')

      MATTERPORT_RE = %r{https?://(?:my\.)?matterport\.com/show/\?[^\s"'<>)]*m=[A-Za-z0-9]+[^\s"'<>)]*}i

      def crawl_delay
        Integer(source.config['crawl_delay'] || 5)
      end

      def discover(limit: nil)
        keys = project_index.keys
        limit ? keys.first(limit) : keys
      rescue StandardError => e
        Rails.logger.warn "[#{self.class.name}] discovery failed: #{e.message}"
        []
      end

      def fetch(key)
        entry = project_index[key.to_s]
        return nil if entry.nil?

        { key: key.to_s, url: entry['link'], entry: entry, html: http_get(entry['link']) }
      end

      def parse(raw)
        doc   = raw[:html].present? ? Nokogiri::HTML(raw[:html]) : nil
        entry = raw[:entry]
        terms = term_names(entry)
        name  = extract_name(entry)
        spec  = self.class.spec_for(raw[:key])

        NormalizedHome.new(
          source_key:       raw[:key],
          source_url:       raw[:url],
          model_name:       name,
          model_id:         spec['model_id'],
          series:           extract_series(terms),
          property_type:    terms.grep(WIDTH_RE),
          bedrooms:         extract_bedrooms(terms),
          bathrooms:        spec['bathrooms'],
          square_feet:      spec['square_feet'],
          dimensions:       spec['dimensions'],
          images:           extract_images(entry, doc) + floor_plan_images(spec, name),
          virtual_tour_url: scan_regex(raw[:html], MATTERPORT_RE),
          raw:              { 'porch_model' => terms.any? { |t| t.casecmp?('porch model') },
                              'plan_pdf_url' => spec['plan_pdf_url'] }.compact
        )
      end

      def diagnostics
        url   = projects_url(1)
        probe = http_probe(url, accept: 'application/json')
        out = {
          adapter:      'live_oak',
          url:          url,
          status:       probe[:status],
          bytes:        probe[:bytes],
          redirect:     probe[:location],
          server:       probe[:server],
          content_type: probe[:content_type]
        }
        out[:error] = probe[:error] if probe[:error]
        out[:looks_blocked] = looks_blocked?(probe[:body]) if probe[:body].present?
        out
      end

      # The floor plan sheet values for one slug, or {} when there is none.
      def self.spec_for(slug)
        spec_sheet.fetch(slug.to_s, {})
      end

      def self.spec_sheet
        @spec_sheet ||= JSON.parse(File.read(SPEC_SHEET)).fetch('homes', {})
      end

      # Lets ParsedHomeCache treat homes parsed under an older spec sheet as stale.
      def self.data_fingerprint
        @data_fingerprint ||= Digest::SHA256.file(SPEC_SHEET).hexdigest
      end

      private

      # Already in our own bucket, so local_url is set and the image archiver
      # leaves it alone instead of copying it a second time.
      def floor_plan_images(spec, name)
        url = spec['floor_plan_url']
        return [] if url.blank?

        [{ 'source_url' => url, 'local_url' => url, 'alt' => "#{name} floor plan".strip, 'is_floorplan' => true }]
      end

      # slug => REST entry, across every page. One failed page raises rather
      # than returning a short list: a run reads homes it did not see as removed
      # from the catalog and would inactivate them on every subscribed dealer.
      def project_index
        @project_index ||= begin
          index = {}
          (1..REST_MAX_PAGES).each do |page|
            body = http_get(projects_url(page), accept: 'application/json')
            raise "no response for project page #{page}" if body.blank?

            rows = JSON.parse(body)
            rows.each { |row| index[row['slug'].to_s] = row if row['slug'].present? }
            break if rows.size < REST_PAGE_SIZE
          end
          index
        end
      end

      def projects_url(page)
        "#{site_root}#{REST_PROJECTS}?per_page=#{REST_PAGE_SIZE}&page=#{page}" \
          "&_fields=#{REST_FIELDS}&_embed=#{REST_EMBED}"
      end

      def site_root
        uri = URI.parse(source.base_url.to_s)
        "#{uri.scheme}://#{uri.host}"
      end

      def extract_name(entry)
        Nokogiri::HTML.fragment(entry.dig('title', 'rendered').to_s).text.strip.presence
      end

      def term_names(entry)
        Array(entry.dig('_embedded', 'wp:term')).flatten
                                                .select { |t| t.is_a?(Hash) && t['taxonomy'] == TAXONOMY }
                                                .filter_map { |t| Nokogiri::HTML.fragment(t['name'].to_s).text.strip.presence }
      end

      def extract_bedrooms(terms)
        terms.filter_map { |t| t[BEDROOMS_RE, 1] }.first&.to_i
      end

      def extract_series(terms)
        terms.find do |term|
          !term.match?(BEDROOMS_RE) && !term.match?(WIDTH_RE) && !NON_SERIES_TERMS.include?(term.downcase)
        end
      end

      # Featured photo first, since the first image becomes the listing photo
      # and the gallery's own order is arbitrary. Gallery links hold the full
      # size image; the <img> inside is a 400x284 crop. The page hero is a CSS
      # background shared by every home, so scoping to gallery items excludes it.
      def extract_images(entry, doc)
        seen = {}
        featured = Array(entry.dig('_embedded', 'wp:featuredmedia')).first
        add_image(seen, featured['source_url'], featured['alt_text']) if featured.is_a?(Hash)

        doc&.css('.et_pb_gallery_item')&.each do |item|
          add_image(seen, item.at_css('a[href]')&.[]('href'), item.at_css('.et_pb_gallery_title')&.text)
        end
        seen.values
      end

      def add_image(seen, url, alt)
        return if url.blank? || !url.include?('/wp-content/uploads/')

        seen[url] ||= { 'source_url' => url, 'local_url' => nil, 'alt' => alt.to_s.strip, 'is_floorplan' => false }
      end
    end
  end
end
