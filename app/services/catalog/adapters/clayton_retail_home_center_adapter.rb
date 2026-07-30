# frozen_string_literal: true

module Catalog
  module Adapters
    # Adapter for a single Clayton RETAIL home center on claytonhomes.com —
    # i.e. what one retailer can actually order, not Clayton's national catalog.
    #
    # This is a different site and a different concept from ClaytonEpicRegionAdapter
    # (claytonepicexperience.com), which partitions a national model catalog into
    # six geographic regions. Here, each CatalogSource is ONE home center, and
    # Clayton itself decides that retailer's orderable list. That solves dealer
    # scoping at the source: a dealer subscribed to their own home center gets
    # their homes and nobody else's, with no radius math on our side.
    #
    #   base_url: https://www.claytonhomes.com/locations/{navigationSlug}
    #
    # Verified catalog sizes differ per retailer (Mobile Home Masters 53, A-1 Fort
    # Worth 60, Bowdon 208, Athens GA 255), confirming these are genuinely
    # retailer-specific rather than a shared national list.
    #
    # Two surfaces are combined:
    #   1. /locations/{slug}          -> dealer identity, orderable models, in-stock SKUs
    #   2. /homes-for-sale/manufactured-homes/near/{city}-{state}-{zip}
    #                                 -> STARTING PRICE per model, localized to
    #                                    this home center's own market
    #
    # The two surfaces share no key (the home center gives modelNumber/SKU, the
    # geo listing gives modelId/navigationSlug), so price is joined on a
    # normalized model name. Measured coverage: 90% (54/60) for Fort Worth, 75%
    # (40/53) for Tyler. Models a retailer can order but that Clayton does not
    # merchandise in that market simply carry no starting price — they still
    # ingest, so price is deliberately NOT a tracked extraction field.
    class ClaytonRetailHomeCenterAdapter < BaseAdapter
      include Catalog::NextFlightPayload

      SITE_ROOT       = 'https://www.claytonhomes.com'
      CLAYTON_IMG_RE  = %r{\Ahttps?://(?:media\.ffycdn\.net|api\.claytonhomes\.com)/}i
      # Shared Clayton SKU tail: width(2) length(2) beds(1) suffix(2).
      SKU_RE          = /(?<width>\d{2})(?<length>\d{2})(?<beds>\d)(?<suffix>[A-Z]{2})\z/
      TOUR_HOSTS_RE   = %r{https?://(?:my\.)?(?:matterport\.com|momento360\.com)/[^\s"'<>)]+}i
      GEO_PAGE_LIMIT  = 15 # safety stop; ~24 results/page
      FEATURES_HEADING = '"children":"Home features"'
      FEATURES_WINDOW  = 8_000
      FEATURE_ITEM_RE  = /\["\$","li","([^"]+)"/

      def crawl_delay
        Integer(source.config['crawl_delay'] || 5)
      end

      # Returns this home center's orderable model numbers (SKUs).
      def discover(limit: nil)
        load_home_center!
        keys = @cards.keys
        limit ? keys.first(limit) : keys
      rescue StandardError => e
        Rails.logger.warn "[#{self.class.name}] discovery failed: #{e.class}: #{e.message}"
        []
      end

      # Detail page carries the full-resolution gallery (~17 images) and the
      # schema.org Product block; the listing card supplies name/beds/baths/sqft
      # and is the fallback when a detail page 404s or is thin.
      def fetch(key)
        load_home_center!
        url  = "#{site_root}/locations/#{slug}/homes/#{key}"
        html = http_get(url)

        {
          key:       key.to_s,
          url:       url,
          html:      html,
          card:      @cards[key.to_s] || {},
          in_stock:  @in_stock.include?(key.to_s),
          price:     starting_price_for(@cards.dig(key.to_s, 'modelName')),
          dealer:    @dealer
        }
      end

      def parse(raw)
        doc  = raw[:html].present? ? Nokogiri::HTML(raw[:html]) : nil
        card = raw[:card] || {}
        prod = product_json(doc)
        sku  = raw[:key].to_s.upcase.presence
        dec  = decode_sku(sku)

        beds  = card['beds']        || property_value(prod, 'Bedrooms')
        baths = card['baths']       || property_value(prod, 'Bathrooms')
        sqft  = card['squareFeet']  || property_value(prod, 'Square feet')

        NormalizedHome.new(
          source_key:       raw[:key],
          source_url:       raw[:url],
          model_name:       (prod && prod['name'].presence) || card['modelName'],
          model_id:         sku,
          series:           card['seriesName'].presence,
          property_type:    dec ? [dec[:property_type]] : [],
          bedrooms:         beds,
          bathrooms:        baths,
          dimensions:       dec && dec[:dimensions],
          square_feet:      sqft,
          # Clayton publishes no prose blurb for retail models: the detail page
          # goes straight from the spec line to "Home features".
          description:      nil,
          features:         extract_features(raw[:html]),
          images:           extract_images(prod, card),
          virtual_tour_url: scan_regex(raw[:html].to_s, TOUR_HOSTS_RE),
          video_url:        nil,
          price_quote_url:  nil,
          raw: {
            'starting_price' => raw[:price],
            'in_stock'       => raw[:in_stock],
            'home_center'    => raw[:dealer],
            'source'         => 'clayton_retail_home_center'
          }.compact
        )
      end

      def diagnostics
        probe = http_probe(base_url)
        out = {
          adapter:     'clayton_retail_home_center',
          slug:        slug,
          listing_url: base_url,
          http_status: probe[:status],
          bytes:       probe[:bytes],
          redirect:    probe[:location]
        }
        out[:error] = probe[:error] if probe[:error]
        if probe[:body].present?
          flight = flight_payload(probe[:body])
          out[:flight_bytes]  = flight.bytesize
          out[:card_count]    = cards_container(flight)&.dig('cards')&.size
          out[:dealer_found]  = dealer_identity(flight).present?
          out[:looks_blocked] = looks_blocked?(probe[:body])
        end
        out
      end

      # Dealer identity for this home center, for display at subscription time.
      def home_center
        load_home_center!
        @dealer
      rescue StandardError
        nil
      end

      private

      # One fetch of the home center page populates cards, in-stock SKUs and
      # dealer identity; the geo price map is derived from the dealer's own
      # city/state/zip so pricing reflects THIS market.
      def load_home_center!
        return if @loaded

        html   = http_get(base_url)
        raise "home center page unavailable: #{base_url}" if html.blank?

        flight = flight_payload(html)
        # Both blocks describe the same retailer but carry different fields: the
        # flight record has the dealer id/number, the LD+JSON store has the
        # parsed address and geo. Merge so the address is always structured.
        @dealer   = (dealer_from_ld_json(html) || {}).merge(dealer_identity(flight) || {})
        @cards    = index_cards(flight)
        @in_stock = in_stock_ids(flight)
        @prices   = pull_prices? ? geo_price_map : {}
        @loaded   = true
      end

      def index_cards(flight)
        container = cards_container(flight)
        Array(container && container['cards']).each_with_object({}) do |card, acc|
          num = card['modelNumber'].to_s.strip
          acc[num] = card if num.present?
        end
      end

      def cards_container(flight)
        decode_object_containing(flight, '"cards":')
      end

      # inStockIds is emitted as a lazy reference ("$W7c") pointing at a separate
      # flight chunk holding the SKU array, so resolve the reference rather than
      # reading the field directly.
      def in_stock_ids(flight)
        container = cards_container(flight)
        chunk_id = container.is_a?(Hash) ? container['inStockIds'].to_s[/\A\$W([0-9a-f]+)\z/, 1] : nil
        return [] unless chunk_id

        m = flight.match(/^#{Regexp.escape(chunk_id)}:(\[[^\]]*\])/m) ||
            flight.match(/#{Regexp.escape(chunk_id)}:(\["[A-Z0-9"',\s]*\])/m)
        return [] unless m

        Array(JSON.parse(m[1])).map(&:to_s)
      rescue JSON::ParserError
        []
      end

      def dealer_identity(flight)
        rec = decode_object_containing(flight, '"dealerNumber":')
        return nil unless rec.is_a?(Hash) && rec['dealerNumber'].present?

        {
          'dealer_id'     => rec['dealerId'],
          'dealer_number' => rec['dealerNumber'],
          'name'          => rec['dealerName'],
          'phone'         => rec['dealerPhone'],
          'email'         => rec['dealerEmail'],
          'address'       => rec['dealerAddress'],
          'brand'         => rec['dealerBrand'],
          'slug'          => slug
        }.compact
      end

      # schema.org HomeGoodsStore block — the authoritative address, and the
      # input for building this market's geo pricing URL.
      def dealer_from_ld_json(html)
        store = ld_json_blocks(Nokogiri::HTML(html)).find { |d| d['@type'] == 'HomeGoodsStore' }
        return nil unless store

        addr = store['address'] || {}
        {
          'name'        => store['name'],
          'phone'       => store['telephone'],
          'email'       => store['email'],
          'brand'       => store['brand'],
          'street'      => addr['streetAddress'],
          'city'        => addr['addressLocality'],
          'state'       => addr['addressRegion'],
          'postal_code' => addr['postalCode'],
          'latitude'    => store.dig('geo', 'latitude'),
          'longitude'   => store.dig('geo', 'longitude'),
          'slug'        => slug
        }.compact
      end

      # Starting prices are opt-in per source: the dealer may not want to manage
      # them at all, in which case we skip the extra geo fetches entirely.
      def pull_prices?
        source.config.fetch('include_starting_price', true) != false
      end

      # Walk the geo listing for this home center's own city/state/zip and build
      # { normalized_model_name => price }.
      def geo_price_map
        loc = geo_slug
        return {} if loc.blank?

        prices = {}
        total  = nil
        (1..GEO_PAGE_LIMIT).each do |page|
          html = http_get("#{site_root}/homes-for-sale/manufactured-homes/near/#{loc}?page=#{page}")
          break if html.blank?

          payload = decode_object_containing(flight_payload(html), '"results":')
          results = Array(payload && payload['results'])
          break if results.empty?

          total ||= payload['total']
          results.each do |r|
            name = normalize_name(r['modelName'])
            prices[name] = r['price'] if name.present? && r['price'].present?
          end
          break if total && prices.size >= total.to_i
          break if results.size < 5

          sleep crawl_delay
        end
        prices
      rescue StandardError => e
        Rails.logger.warn "[#{self.class.name}] price map failed: #{e.class}: #{e.message}"
        {}
      end

      # "Tyler", "TX", "75705" -> "tyler-tx-75705"
      def geo_slug
        override = source.config['geo_slug']
        return override.to_s if override.present?

        city  = (@dealer['city'] || @dealer.dig('address').to_s[/\A([^,]+),/, 1]).to_s
        state = @dealer['state'].to_s
        zip   = @dealer['postal_code'].to_s
        if city.blank? || state.blank? || zip.blank?
          parsed = parse_address(@dealer['address'])
          city  = parsed[:city]  if city.blank?
          state = parsed[:state] if state.blank?
          zip   = parsed[:zip]   if zip.blank?
        end
        return nil if city.blank? || state.blank? || zip.blank?

        "#{city.parameterize}-#{state.downcase}-#{zip}"
      end

      # "12010 State Hwy 31 E, Tyler, TX 75705"
      def parse_address(address)
        m = address.to_s.match(/,\s*([^,]+),\s*([A-Z]{2})\s+(\d{5})/)
        m ? { city: m[1].strip, state: m[2], zip: m[3] } : {}
      end

      def starting_price_for(model_name)
        return nil if model_name.blank?

        @prices[normalize_name(model_name)]
      end

      def normalize_name(name)
        name.to_s.downcase.gsub(/[^a-z0-9]/, '')
      end

      def product_json(doc)
        return nil unless doc

        ld_json_blocks(doc).find { |d| d['@type'] == 'Product' }
      end

      def ld_json_blocks(doc)
        doc.css('script[type="application/ld+json"]').filter_map do |node|
          JSON.parse(node.text)
        rescue JSON::ParserError
          nil
        end
      end

      def property_value(product, label)
        return nil unless product

        Array(product['additionalProperty'])
          .find { |p| p['name'].to_s.casecmp?(label) }&.dig('value')
      end

      # Prefer the detail page's full-resolution gallery; fall back to the card
      # thumbnails so a home still satisfies the smoke test if detail 404s.
      def extract_images(product, card)
        srcs = Array(product && product['image'])
        alts = {}
        if srcs.empty?
          Array(card['thumbnailImages']).each do |img|
            src = img['src'].to_s
            next if src.blank?

            srcs << src
            alts[strip_query(src)] = img['alt']
          end
        end

        seen = {}
        srcs.each do |raw_src|
          src = strip_query(raw_src)
          next if src.blank? || !src.match?(CLAYTON_IMG_RE)
          next if src.match?(/logo|icon/i)

          alt = alts[src]
          seen[src] ||= {
            'source_url'   => src,
            'local_url'    => nil,
            'alt'          => alt,
            # Clayton labels floor plan art in the alt text ("… — floor plan")
            # and segments it under /images/mfg/flp/ on the legacy CDN.
            'is_floorplan' => src.include?('/images/mfg/flp/') || alt.to_s.match?(/floor\s*plan/i)
          }
        end
        seen.values
      end

      # "Home features" (Kitchen island, Split bedroom, ...) is client-rendered,
      # so it exists only in the flight payload, not the served DOM. Each entry
      # is a list item keyed by its own label: ["$","li","Kitchen island",{...}].
      # Scan from the section heading to the next heading so unrelated <li> keys
      # elsewhere on the page can't bleed in.
      def extract_features(html)
        flight = flight_payload(html)
        return {} if flight.blank?

        start = flight.index(FEATURES_HEADING)
        return {} unless start

        window = flight[start, FEATURES_WINDOW].to_s
        stop   = window.index('"h2"', FEATURES_HEADING.length)
        window = window[0, stop] if stop

        items = window.scan(FEATURE_ITEM_RE).flatten.map(&:strip).reject(&:empty?).uniq
        items.any? ? { 'Home features' => items } : {}
      rescue StandardError => e
        Rails.logger.warn "[#{self.class.name}] feature extraction failed: #{e.class}: #{e.message}"
        {}
      end

      def strip_query(src)
        src.to_s.split('?').first
      end

      def decode_sku(sku)
        return nil if sku.blank?

        m = sku.match(SKU_RE)
        return nil unless m

        width = m[:width].to_i
        { dimensions: "#{width}x#{m[:length].to_i}",
          property_type: width >= 20 ? 'Double Wide' : 'Single Wide' }
      end

      def slug
        base_url.split('/locations/').last.to_s.split(/[?#]/).first.to_s.sub(%r{/+\z}, '')
      end

      def site_root
        uri = URI.parse(source.base_url.to_s)
        "#{uri.scheme}://#{uri.host}"
      rescue StandardError
        SITE_ROOT
      end
    end
  end
end
