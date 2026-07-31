# frozen_string_literal: true

module Catalog
  # Upserts normalized homes into ONE company's inventory, riding the existing
  # Vehicle path (same as Champion). Dedup key is (catalog_source_id,
  # catalog_source_key); change detection is catalog_content_hash. Homes missing
  # from a run are marked inactive (soft-deleted) — never hard-deleted.
  #
  # `protect_blanks: true` (set by RunService on a degraded run) refuses to
  # overwrite a previously-populated field with a blank, so a markup break can't
  # wipe good data.
  class IngestionService
    VEHICLE_SOURCE = 'catalog_import'
    # Onboarding seed rows (Cavco inventory): real dealer vehicles carrying real
    # statuses, NOT catalog rows. Vehicle#catalog_row? keys off `source`, so this
    # keeps them out of the "must stay available_to_order / clone on status
    # change" rule and inside in_inventory counts, where they belong.
    SEEDED_VEHICLE_SOURCE = 'catalog_inventory'

    # Bump when the column MAPPING below changes (not the scraper) so existing
    # rows re-ingest on the next run even though the scraped content is identical.
    # v3: heal catalog rows whose media was damaged by a pre-clone-on-edit direct
    # edit (re-ingest restores the correct {url} image objects).
    # v4: smart re-sync — only refresh a catalog-managed field when the dealer
    # hasn't touched it (current value == previously-synced catalog value).
    INGESTION_VERSION = 4

    # Vehicle fields the catalog owns. On re-sync each is updated ONLY when the
    # current value matches catalog_last_synced_values[field] (i.e. dealer hasn't
    # edited it since last sync). Everything else on the vehicle (stock_number,
    # status, price, custom_field_values, owner, location-specific data) is
    # dealer-owned and never touched by re-sync.
    MANAGED_FIELDS = %i[
      model bedrooms bathrooms square_feet width length description
      images floor_plan_images photo_url features
      virtual_tour_url matterport_url video_url
    ].freeze

    # Sentinel key inside catalog_last_synced_values marking a vehicle that was
    # stamped by SupplementApplier (was a pre-existing dealer row, not created by
    # ingestion). Lets re-sync preserve `source` and lets unsubscribe un-stamp
    # instead of soft-deleting alongside pure catalog rows. Double-underscore so
    # it can never collide with a real vehicle attribute name.
    SUPPLEMENT_MARK = '__supplemented__'

    def self.supplemented?(vehicle)
      vehicle.catalog_last_synced_values&.[](SUPPLEMENT_MARK) == true
    end

    Result = Struct.new(:added, :updated, :unchanged, :inactivated, keyword_init: true)

    # Maps a NormalizedHome → the hash of catalog-managed attributes a vehicle
    # would receive. Pulled out of #assign_attributes! so the SupplementApplier
    # can build the same payload without duplicating the field map.
    def self.catalog_attrs_from(home, source:)
      gallery_imgs = home.images.reject { |i| (i['is_floorplan'] == true) || (i['is_floorplan'].to_s == 'true') }
      gallery_imgs = home.images if gallery_imgs.empty?
      gallery      = url_images(gallery_imgs)
      floor_pl     = url_images(home.floorplan_images)
      w, l         = parse_dimensions(home.dimensions)
      virtual_tour = home.virtual_tour_url

      {
        model:             home.model_name,
        bedrooms:          home.bedrooms,
        bathrooms:         home.bathrooms,
        square_feet:       home.square_feet,
        width:             w,
        length:            l,
        description:       home.description,
        images:            gallery,
        floor_plan_images: floor_pl,
        photo_url:         gallery.first&.dig('url'),
        features:          home.features.flat_map { |section, items| Array(items).map { |i| "#{section}: #{i}" } },
        virtual_tour_url:  virtual_tour,
        matterport_url:    (virtual_tour if virtual_tour.to_s.include?('matterport')),
        video_url:         home.video_url
      }
    end

    def self.url_images(images)
      Array(images).filter_map do |img|
        url = img['local_url'].presence || img['source_url'] || img['url']
        next if url.blank?

        { 'url' => url, 'alt' => img['alt'].to_s }
      end
    end

    def self.parse_dimensions(dims)
      return [nil, nil] if dims.blank?

      parts = dims.to_s.split(/[xX×]/, 2)
      [parts[0].to_s[/\d+/]&.to_i, parts[1].to_s[/\d+/]&.to_i]
    end

    def initialize(company:, source:, location_id: nil, protect_blanks: false)
      @company        = company
      @source         = source
      @location_id    = location_id
      @protect_blanks = protect_blanks
    end

    # @param homes [Array<NormalizedHome>]
    # @return [Result]
    def call(homes)
      result    = Result.new(added: 0, updated: 0, unchanged: 0, inactivated: 0)
      seen_keys = []

      homes.each do |home|
        seen_keys << home.source_key.to_s
        case upsert(home)
        when :added     then result.added += 1
        when :updated   then result.updated += 1
        when :unchanged then result.unchanged += 1
        end
      end

      result.inactivated = inactivate_missing(seen_keys)
      result
    end

    private

    def upsert(home)
      # Dedup per (source, source_key, location) so each subscribed location gets
      # its own Vehicle copy (a Vehicle has a single location_id).
      vehicle = @company.vehicles.find_or_initialize_by(
        catalog_source_id:  @source.id,
        catalog_source_key: home.source_key.to_s,
        location_id:        @location_id
      )
      is_new = vehicle.new_record?

      # Unchanged: same content signature on an existing row → just refresh
      # last-seen. The signature includes INGESTION_VERSION, so bumping that
      # forces every row to re-ingest when the column MAPPING changes (even
      # though the scraped content didn't).
      if !is_new && vehicle.catalog_content_hash == content_signature(home)
        vehicle.update_columns(catalog_last_seen_at: Time.current, is_deleted: false, deleted_at: nil)
        return :unchanged
      end

      assign_attributes!(vehicle, home, is_new: is_new)

      unless vehicle.save
        Rails.logger.warn "[Catalog::IngestionService] skip #{home.source_key} for company " \
                          "#{@company.id}: #{vehicle.errors.full_messages.join(', ')}"
        return nil
      end

      is_new ? :added : :updated
    end

    def assign_attributes!(vehicle, home, is_new:)
      catalog_values = self.class.catalog_attrs_from(home, source: @source)

      # Smart write for managed fields: on a NEW catalog row, write everything;
      # on an existing row, only overwrite a field when the dealer hasn't touched
      # it since the last sync (current value matches what catalog last produced).
      last_synced = (vehicle.catalog_last_synced_values || {}).dup
      MANAGED_FIELDS.each do |field|
        new_value = catalog_values[field]

        if @protect_blanks && !is_new && blank_incoming?(new_value) && vehicle.public_send(field).present?
          # Degraded-run safeguard: never wipe populated data with a blank.
          last_synced[field.to_s] = serialize_for_compare(new_value)
          next
        end

        if is_new || dealer_untouched?(vehicle, field, last_synced)
          vehicle.public_send("#{field}=", new_value)
        end
        # Always record what the catalog produced this time — that's what the
        # next sync compares against to decide "has the dealer touched it?"
        last_synced[field.to_s] = serialize_for_compare(new_value)
      end

      # Non-managed bookkeeping. `source` is preserved for supplemented vehicles
      # (they were dealer-created — overwriting source = 'catalog_import' would
      # erase the only marker that distinguishes them from pure imports).
      vehicle.listing_type         = 'manufactured_home'
      vehicle.source               = VEHICLE_SOURCE unless self.class.supplemented?(vehicle)
      vehicle.condition            = 'new'
      vehicle.make                 = manufacturer_name
      vehicle.status               = 'available_to_order' if is_new
      vehicle.catalog_content_hash = content_signature(home)
      vehicle.catalog_last_seen_at = Time.current
      # Preserve the supplement sentinel through subsequent re-syncs.
      last_synced[SUPPLEMENT_MARK] = true if self.class.supplemented?(vehicle)
      vehicle.catalog_last_synced_values = last_synced
      vehicle.is_deleted           = false
      vehicle.deleted_at           = nil

      # Required-on-create fields the feed doesn't carry.
      vehicle.year          ||= Date.current.year
      # Per-location serial keeps the MH uniqueness constraint happy across copies.
      vehicle.serial_number ||= "CAT-#{@source.id}-#{home.source_key}#{@location_id ? "-L#{@location_id}" : ''}"
      vehicle.location_id     = @location_id
      vehicle.catalog_source_id  = @source.id
      vehicle.catalog_source_key = home.source_key.to_s
    end

    # True when the dealer hasn't edited this field since the last sync:
    # either it's still blank, or its current value matches what catalog had
    # last time. Either case is safe to refresh with the new catalog value.
    def dealer_untouched?(vehicle, field, last_synced)
      current = vehicle.public_send(field)
      prev    = last_synced[field.to_s]
      return true if current.blank? && prev.nil?

      serialize_for_compare(current) == prev
    end

    # JSONB-safe comparable form. JSONB returns hashes/arrays with string keys,
    # so normalize both sides before comparing.
    def serialize_for_compare(value)
      case value
      when nil      then nil
      when Array    then value.map { |v| v.is_a?(Hash) ? v.deep_stringify_keys : v }
      when Hash     then value.deep_stringify_keys
      else value
      end
    end

    def blank_incoming?(value)
      value.nil? || (value.respond_to?(:empty?) && value.empty?)
    end

    def inactivate_missing(seen_keys)
      # Scoped to THIS location so ingesting one location doesn't tombstone
      # another location's copies.
      scope = @company.vehicles
                      .where(catalog_source_id: @source.id, location_id: @location_id, is_deleted: [false, nil])
      scope = scope.where.not(catalog_source_key: seen_keys) if seen_keys.any?

      count = 0
      scope.find_each do |vehicle|
        # Never tombstone a supplemented vehicle — it's a dealer-original row
        # that we attached catalog data to. Catalog dropping the model just
        # means the dealer keeps it as-is.
        next if self.class.supplemented?(vehicle)
        # Nor a seeded inventory row. Those are the dealer's own homes, imported
        # once at onboarding; a floorplan run must not tombstone them, and a
        # home leaving the manufacturer's index does not un-sell it.
        next if vehicle.source == SEEDED_VEHICLE_SOURCE

        vehicle.update_columns(is_deleted: true, deleted_at: Time.current)
        count += 1
      end
      count
    end

    def content_signature(home)
      "v#{INGESTION_VERSION}:#{home.content_hash}"
    end

    def manufacturer_name
      @source.config['manufacturer_name'].presence || @source.name
    end
  end
end
