# frozen_string_literal: true

module Catalog
  # One-time onboarding seed of a Cavco dealer's actual lot.
  #
  # Cavco is unusual among our sources in genuinely knowing what a dealer has in
  # stock, not just what they may order — 5,149 units network-wide, each with a
  # status and a link back to its floorplan. That is worth importing when a
  # dealer onboards, because DealerTide is empty at that point and this saves
  # re-keying their whole lot, including recent history.
  #
  # THESE ARE NOT CATALOG ROWS. Vehicle#catalog_row? keys off `source`, and
  # catalog rows are required to sit at `available_to_order` (any other status
  # forces a clone) and are excluded from in_inventory counts. Seeded homes
  # carry real statuses and ARE inventory, so they use a distinct source and are
  # skipped by the catalog tombstoning path.
  #
  # IDEMPOTENT BY DESIGN, AND DELIBERATELY WRITE-ONCE.
  # Identity is Cavco's stable inventory UUID, never the status. So the case
  # that matters — we import a pending home, the dealer marks it sold, Cavco is
  # slow to catch up and still reports pending — resolves to "already seeded,
  # leave it alone". No duplicate, and no fighting the dealer over status.
  class CavcoInventorySeeder
    # Cavco's availability values, mapped onto Vehicle::STATUSES.
    STATUS_MAP = {
      'available'      => 'available',
      'priced to move' => 'available',
      'display home'   => 'available',
      'under contract' => 'pending',
      'sold'           => 'sold'
    }.freeze

    DEFAULT_STATUS = 'available'
    CDN_RE = %r{\Ahttps?://[a-z0-9.\-]*cavco\.com/}i

    Result = Struct.new(:created, :skipped_existing, :skipped_unmappable, keyword_init: true)

    def initialize(company:, source:, location_id: nil)
      @company     = company
      @source      = source
      @location_id = location_id
    end

    # @param documents [Array<Hash>] flattened Cavco inventory documents
    def call(documents)
      result = Result.new(created: 0, skipped_existing: 0, skipped_unmappable: 0)

      Array(documents).each do |doc|
        key = doc['id'].to_s
        if key.blank?
          result.skipped_unmappable += 1
          next
        end

        # Write-once: presence is decided by Cavco's UUID alone, so a stale
        # status upstream can never resurrect a home the dealer has moved on.
        if existing?(key)
          result.skipped_existing += 1
          next
        end

        vehicle = build_vehicle(doc, key)
        if vehicle.save
          result.created += 1
        else
          Rails.logger.warn "[Catalog::CavcoInventorySeeder] skip #{key} for company " \
                            "#{@company.id}: #{vehicle.errors.full_messages.join(', ')}"
          result.skipped_unmappable += 1
        end
      end

      result
    end

    def self.status_for(availability)
      STATUS_MAP.fetch(availability.to_s.downcase.strip, DEFAULT_STATUS)
    end

    private

    def existing?(key)
      @company.vehicles.where(catalog_source_id: @source.id, catalog_source_key: key).exists?
    end

    def build_vehicle(doc, key)
      images = build_images(doc)

      @company.vehicles.build(
        listing_type:  'manufactured_home',
        # Marks these as an onboarding seed rather than a catalog row, which is
        # what keeps them out of catalog_row? and inside in_inventory.
        source:        Catalog::IngestionService::SEEDED_VEHICLE_SOURCE,
        status:        self.class.status_for(doc['inventory_availability']),
        condition:     doc['sale_type'].to_s.casecmp('pre-owned').zero? ? 'used' : 'new',
        make:          doc['brand_name'].presence || @source.name,
        model:         model_for(doc),
        year:          ship_year(doc) || Date.current.year,
        bedrooms:      positive_int(doc['number_of_bedrooms']),
        bathrooms:     decimal(doc['number_of_bathrooms']),
        square_feet:   positive_int(doc['square_foot']),
        width:         dimension(doc, 0),
        length:        dimension(doc, 1),
        images:        images,
        photo_url:     images.first&.dig('url'),
        virtual_tour_url: tour_for(doc),
        matterport_url:   tour_for(doc),
        location_id:   @location_id,
        # Identity for idempotency. NOT a catalog row — `source` decides that —
        # but these columns are exactly what "which upstream record is this"
        # means, and IngestionService skips seeded rows when tombstoning.
        catalog_source_id:  @source.id,
        catalog_source_key: key,
        catalog_last_seen_at: Time.current,
        # Manufactured homes require a serial and Cavco publishes none, so this
        # is a placeholder in the same shape ingestion already uses. The dealer
        # owns the row and can replace it with the real serial off the HUD tag.
        serial_number: "CAVCO-INV-#{@source.id}-#{key}#{@location_id ? "-L#{@location_id}" : ''}",
        # Cavco's selling_price is free text — ~90% "Call for Pricing", the rest
        # marketing copy ("Sizzlin Summer SALE!!!"). It never becomes a number.
        notes: price_note(doc)
      )
    end

    def model_for(doc)
      [doc['name'].presence, doc['model_number'].presence].compact.join(' ').presence ||
        doc['model_number'].presence || 'Unknown model'
    end

    # Inventory documents carry no width/length fields, only the model number,
    # so the nominal size encoded there is the only dimension available.
    def dimension(doc, index)
      match = doc['model_number'].to_s.match(/\A(\d{2})(\d{2})(\d)/)
      return nil unless match

      beds = positive_int(doc['number_of_bedrooms'])
      return nil unless beds && match[3].to_i == beds

      value = match[index + 1].to_i
      value.positive? ? value : nil
    end

    def ship_year(doc)
      Time.zone.parse(doc['ship_date'].to_s)&.year
    rescue ArgumentError, TypeError
      nil
    end

    def build_images(doc)
      decode(doc['photos']).filter_map do |img|
        url = img['url'].to_s
        next if url.blank? || !url.match?(CDN_RE)

        { 'url' => url, 'alt' => img['alt'].to_s }
      end.uniq { |i| i['url'] }
    end

    def decode(value)
      return value.select { |v| v.is_a?(Hash) } if value.is_a?(Array)
      return [] if value.blank?

      parsed = JSON.parse(value.to_s)
      parsed.is_a?(Array) ? parsed.select { |v| v.is_a?(Hash) } : []
    rescue JSON::ParserError
      []
    end

    def tour_for(doc)
      tour = doc['3d_tour'].to_s
      tour.match?(%r{https?://(?:my\.)?matterport\.com/}i) ? tour : nil
    end

    def price_note(doc)
      listed = doc['selling_price'].to_s.strip
      return nil if listed.blank?

      "Cavco listed price: #{listed}"
    end

    def positive_int(value)
      int = value.to_i
      int.positive? ? int : nil
    end

    def decimal(value)
      f = value.to_f
      return nil unless f.positive?

      (f % 1).zero? ? f.to_i : f
    end
  end
end
