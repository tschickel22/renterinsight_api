# frozen_string_literal: true

module Catalog
  module Adapters
    # Trove-hosted manufacturer catalogs (trove.legacyhousing.com and siblings).
    #
    # Trove is a Next.js App Router platform, so the whole catalog ships in the
    # RSC flight payload of ONE page (/homes) — 93 fully structured records for
    # Legacy, each with price, dimensions, bed/bath and section count. That
    # makes discovery a single fetch; detail pages are visited only to collect
    # the photo gallery, which the index does not carry.
    #
    # TWO IMPORTANT SITE FACTS
    #
    # 1. Crawl rights differ per host. The manufacturer catalog
    #    (trove.legacyhousing.com) allows crawling and publishes a sitemap. The
    #    per-dealer storefronts (*.buildtrove.com) are `Disallow: /` in full.
    #    Point this adapter at manufacturer hosts.
    #
    # 2. Both sit behind a Vercel bot checkpoint that answers 429 to any
    #    non-browser client. Until the host allowlists us, run from a snapshot
    #    (see Catalog::TroveSnapshot); the parsing path is identical either way.
    #
    # Dealer vs manufacturer retail: a dealer storefront republishes the same
    # model list with its OWN retail markup. That difference is irrelevant here
    # because IngestionService::MANAGED_FIELDS excludes `price` — retail stays
    # dealer-owned in DealerTide and is never overwritten by a sync.
    class TroveCatalogAdapter < BaseAdapter
      include Catalog::NextFlightPayload

      HOMES_PATH = '/homes'

      # Trove serves all product media from Bunny CDN. Anything else on the page
      # (site logo, marketing art) is not home photography.
      CDN_RE = %r{\Ahttps://[a-z0-9.\-]*b-cdn\.net/}i

      TOUR_RE = %r{https?://(?:my\.)?(?:matterport\.com|momento360\.com)/[^\s"'<>)]+}i

      # A detail page also renders cards for OTHER models, so its flight payload
      # contains their images too. Trove auto-generates alt text from the model
      # name ("Heritage h-3260-32a kitchen home features"), which is the only
      # reliable way to tell this home's gallery from its neighbours'.
      IMAGE_OBJ_MARKER = '"image_url"'
      IMAGE_OBJ_WINDOW = 600
      IMAGE_OBJ_MAX    = 1_200

      SECTION_LABELS = { 1 => 'Single Wide', 2 => 'Double Wide', 3 => 'Triple Wide' }.freeze

      # Legacy writes some SKUs with a multiplication sign ("H-32×72-43A") and
      # some with a trailing qualifier ("O-1680-55AOF HUD"). Normalize the
      # former (it is a typographic variant of "x"), keep the latter (it is
      # meaningful) so model_id stays stable across runs.
      MULTIPLICATION_SIGN = '×'

      def discover(limit: nil)
        keys = index_records.keys
        limit ? keys.first(limit) : keys
      end

      def fetch(key)
        record = index_records[key]
        return nil if record.blank?

        { 'record' => record, 'gallery' => gallery_for(record) }
      end

      def parse(raw)
        record  = raw['record'] || {}
        details = record['details'] || {}
        images  = build_images(raw['gallery'], record)

        NormalizedHome.new(
          source_key:      record['short_id'],
          source_url:      home_url(record['short_id']),
          model_name:      record['name'].to_s.strip.presence,
          model_id:        model_id_for(record),
          series:          series_for(record),
          property_type:   property_type_for(details),
          bedrooms:        positive_int(details['bedrooms']),
          bathrooms:       bathrooms_for(details),
          dimensions:      dimensions_for(details),
          square_feet:     positive_int(details['square_feet']),
          description:     description_for(details),
          features:        features_for(details),
          images:          images,
          virtual_tour_url: tour_for(details),
          raw:             raw_extras(record, details)
        )
      end

      # Snapshot runs never touch the network, so there is nothing to be polite
      # about. Live runs use the configured delay.
      def crawl_delay
        snapshot.present? ? 0 : super
      end

      # Surfaced to the admin Test action so a snapshot-backed run is never
      # mistaken for a live one.
      def snapshot_info
        snap = snapshot
        return nil if snap.blank?

        { 'key' => snapshot_key, 'captured_at' => snap['captured_at'],
          'supplier_name' => snap['supplier_name'], 'home_count' => snap['homes']&.size }
      end

      private

      # ---- sources -----------------------------------------------------------

      # short_id => record, in site order. One fetch (or zero, from a snapshot).
      def index_records
        @index_records ||= begin
          homes = snapshot.present? ? snapshot_homes : crawl_index_homes
          homes.each_with_object({}) do |home, acc|
            key = home['short_id'].to_s
            acc[key] = home if key.present? && !acc.key?(key)
          end
        end
      end

      def snapshot_homes
        Array(snapshot['homes']).map { |h| h.is_a?(Hash) ? h.deep_stringify_keys : nil }.compact
      end

      def crawl_index_homes
        html = http_get(home_index_url)
        if html.blank?
          Rails.logger.warn "[#{self.class.name}] no HTML from #{home_index_url}"
          return []
        end

        product_records(flight_payload(html))
      end

      # Every product object in a flight buffer. Products are identified by the
      # short_id + details + price triple; other objects in the payload (site
      # config, suppliers, nav) carry none of them.
      def product_records(flight)
        return [] if flight.blank?

        found  = []
        seen   = {}
        marker = '"short_id":"'
        idx    = flight.index(marker)

        while idx
          record = decode_record_around(flight, idx, marker)
          if record && !seen.key?(record['short_id'])
            seen[record['short_id']] = true
            found << record
          end
          idx = flight.index(marker, idx + marker.length)
        end
        found
      end

      # Walk left from the marker to the enclosing '{' and decode. The first
      # balanced object that actually looks like a product wins.
      def decode_record_around(flight, idx, marker)
        start = idx
        floor = [0, idx - 3_000].max

        while start > floor
          start = flight.rindex('{', start - 1)
          break if start.nil? || start < floor

          candidate = decode_object(flight, start)
          next if candidate.nil?
          return candidate if product_record?(candidate) && candidate.to_json.include?(marker)
        end
        nil
      end

      def product_record?(obj)
        obj.is_a?(Hash) && obj['short_id'].present? &&
          obj['details'].is_a?(Hash) && obj.key?('price')
      end

      # ---- gallery -----------------------------------------------------------

      # Snapshots carry the gallery inline. Live runs fetch the detail page,
      # which is the only surface with more than a hero + floor plan.
      def gallery_for(record)
        return Array(record['images']) if snapshot.present?

        html = http_get(home_url(record['short_id']))
        return Array(record['images']) if html.blank?

        found = gallery_from_flight(flight_payload(html), record)
        found.presence || Array(record['images'])
      end

      def gallery_from_flight(flight, record)
        return [] if flight.blank?

        model  = record['name'].to_s.downcase.strip
        series = series_for(record).to_s.downcase
        seen   = {}
        idx    = flight.index(IMAGE_OBJ_MARKER)

        while idx
          obj = decode_image_object(flight, idx)
          if obj
            url = obj['image_url'].to_s
            seen[url] = obj if url.match?(CDN_RE) && !seen.key?(url) &&
                               alt_belongs_to?(obj['alt'], model, series)
          end
          idx = flight.index(IMAGE_OBJ_MARKER, idx + IMAGE_OBJ_MARKER.length)
        end
        seen.values
      end

      # Trove auto-generates alt text, but at two levels of specificity, and a
      # detail page carries images for neighbouring models too. Both forms occur
      # on the SAME page:
      #
      #   "Heritage h-3260-32a floor plan home features"  <- model-specific
      #   "Classic kitchen home features"                 <- series-only
      #   "Oilfield hero and exterior home features"      <- a different series
      #
      # Matching only the model name loses the series-only gallery (38% of
      # Legacy's models publish photos that way). Matching the series alone
      # would blend in another model of the same series. So: accept a
      # series-only alt, but the moment the word after the series looks like a
      # model number, it must be OUR model number.
      def alt_belongs_to?(alt, model, series)
        text = alt.to_s.downcase.strip
        return false if text.blank?
        return true  if model.present? && text.start_with?(model)
        return false if series.blank? || !text.start_with?(series)

        next_word = text.delete_prefix(series).strip.split(/\s+/).first.to_s
        !next_word.match?(/\d/)
      end

      def decode_image_object(flight, idx)
        start = idx
        floor = [0, idx - IMAGE_OBJ_WINDOW].max

        while start > floor
          start = flight.rindex('{', start - 1)
          break if start.nil? || start < floor

          candidate = decode_object(flight, start)
          next if candidate.nil?
          return candidate if candidate.is_a?(Hash) && candidate.key?('image_url') &&
                              candidate.to_json.length < IMAGE_OBJ_MAX
        end
        nil
      end

      def build_images(gallery, record)
        source = Array(gallery).presence || Array(record['images'])
        seen   = {}

        source.each do |img|
          next unless img.is_a?(Hash)

          url = img['image_url'].to_s
          next if url.blank? || !url.match?(CDN_RE) || seen.key?(url)

          tags = Array(img['image_tags']).map(&:to_s)
          seen[url] = {
            'source_url'   => url,
            'local_url'    => nil,
            'alt'          => img['alt'],
            # Trove tags floor plan art explicitly; the alt text repeats it.
            'is_floorplan' => tags.include?('floor_plan') || img['alt'].to_s.match?(/floor\s*plan/i)
          }
        end
        seen.values
      end

      # ---- field extractors --------------------------------------------------

      # supplier_sku is the manufacturer's own model number and the stable id,
      # but 7 of Legacy's 93 records omit it. Fall back to the model name minus
      # its series word ("Workforce O-18×80-44A" -> "O-18x80-44A").
      def model_id_for(record)
        sku = normalize_sku(record['supplier_sku'])
        return sku if sku.present?

        tail = record['name'].to_s.strip.split(/\s+/).drop(1).join(' ')
        normalize_sku(tail).presence || record['short_id'].to_s.presence
      end

      def normalize_sku(value)
        value.to_s.tr(MULTIPLICATION_SIGN, 'x').squeeze(' ').strip
      end

      # Trove has no series field; the model name leads with it ("Heritage
      # H-3260-32A"). Verified to resolve for all 93 Legacy models.
      def series_for(record)
        token = record['name'].to_s.strip.split(/\s+/).first.to_s
        token.match?(/\A[A-Za-z][A-Za-z\-]{2,}\z/) ? token : nil
      end

      def property_type_for(details)
        label = SECTION_LABELS[positive_int(details['sections'])]
        label ? [label] : []
      end

      # Trove splits full and half baths; DealerTide carries one decimal.
      def bathrooms_for(details)
        full = positive_int(details['bathrooms'])
        half = positive_int(details['half_bathrooms'])
        return nil if full.nil? && half.nil?

        total = full.to_i + (half.to_i * 0.5)
        return nil if total.zero?

        (total % 1).zero? ? total.to_i : total
      end

      # Dimensions ship in inches; the trade talks in feet ("32x60").
      def dimensions_for(details)
        width  = positive_int(details['width_inches'])
        length = positive_int(details['length_inches'])
        return nil unless width && length

        "#{width / 12}x#{length / 12}"
      end

      # Legacy publishes the description scaffold with empty bodies on every
      # record, so this returns nil in practice. Kept honest (rather than
      # synthesizing copy) and handled with `untracked_fields` on the source.
      def description_for(details)
        Array(details['descriptions'])
          .filter_map { |d| d.is_a?(Hash) ? d['description'].to_s.strip.presence : nil }
          .uniq.join("\n\n").presence
      end

      # Not a TRACKED_FIELD, so this is additive detail rather than a health
      # signal. Only emit what the payload actually states.
      def features_for(details)
        items = []
        sections = positive_int(details['sections'])
        items << SECTION_LABELS[sections] if SECTION_LABELS.key?(sections)
        if (porch = positive_int(details['covered_porch_sqft']))
          items << "Covered porch (#{porch} sq ft)"
        end
        items << 'Kitchen island' if positive_int(details['kitchen_island_sqft'])

        items.any? ? { 'Home details' => items } : {}
      end

      def tour_for(details)
        Array(details['embedded_media_urls']).map(&:to_s).find { |u| u.match?(TOUR_RE) }
      end

      # Price rides in `raw`, never on the NormalizedHome — ingestion treats
      # price as dealer-owned. cost_micros is the manufacturer's invoice cost
      # and is deliberately NOT surfaced here; see the source config docs.
      def raw_extras(record, details)
        {
          'retail_price'  => published_retail_price(record),
          'in_stock'      => record['is_inventory'] == true,
          'price_hidden'  => record['is_price_hidden'] == true,
          'supplier_sku'  => record['supplier_sku'],
          'supplier_id'   => record['supplier_id'],
          'listed_status' => record['listed_status'],
          'sections'      => positive_int(details['sections']),
          'source'        => 'trove'
        }.compact
      end

      # `is_price_hidden` marks a call-for-quote model. Legacy still ships a
      # price on those records, but it is a placeholder ($900 across all 7 of
      # its Workforce units), not something anyone should ever see. Treat a
      # hidden price as no price.
      def published_retail_price(record)
        return nil if record['is_price_hidden'] == true

        micros_to_dollars(record.dig('price', 'retail_micros'))
      end

      # Trove's "micros" are hundredths, not millionths: 5_590_000 is $55,900.
      # Verified against the rendered price on the dealer storefront.
      def micros_to_dollars(value)
        cents = value.to_i
        return nil unless cents.positive?

        (cents / 100.0).round(2)
      end

      def positive_int(value)
        int = value.to_i
        int.positive? ? int : nil
      end

      # ---- config ------------------------------------------------------------

      def snapshot
        return @snapshot if defined?(@snapshot)

        @snapshot = snapshot_key.present? ? TroveSnapshot.read(snapshot_key) : nil
      end

      def snapshot_key
        source.config.is_a?(Hash) ? source.config['snapshot_key'].presence : nil
      end

      # Trove serves the catalog from the host root, so only scheme + host
      # matter. Admins reasonably paste the URL they were looking at
      # ("…/catalog", "…/homes"), which would otherwise build "/catalog/homes"
      # and silently discover nothing. Normalize to the origin.
      def site_root
        raw = (snapshot && snapshot['base_url'].presence || source.base_url).to_s.strip
        return '' if raw.blank?

        uri = URI.parse(raw)
        return raw.chomp('/') if uri.host.blank?

        "#{uri.scheme || 'https'}://#{uri.host}#{uri.port && ![80, 443].include?(uri.port) ? ":#{uri.port}" : ''}"
      rescue URI::InvalidURIError
        raw.chomp('/')
      end

      def home_index_url
        "#{site_root}#{HOMES_PATH}"
      end

      def home_url(short_id)
        "#{site_root}#{HOMES_PATH}/#{short_id}"
      end
    end
  end
end
