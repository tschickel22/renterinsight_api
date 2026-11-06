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
    # v5: building_code (HUD / modular / park model) from the home's property type.
    INGESTION_VERSION = 5

    # Vehicle fields the catalog owns. On re-sync each is updated ONLY when the
    # current value matches catalog_last_synced_values[field] (i.e. dealer hasn't
    # edited it since last sync). Everything else on the vehicle (stock_number,
    # status, price, custom_field_values, owner, location-specific data) is
    # dealer-owned and never touched by re-sync.
    MANAGED_FIELDS = %i[
      model bedrooms bathrooms square_feet width length description
      images floor_plan_images photo_url features
      virtual_tour_url matterport_url video_url building_code
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

    # How long a home stays held after a run in which most of its catalog vanished.
    # Long enough for several weekly crawls, so a crawl that keeps dying partway
    # has time to be noticed. Short enough that a real catalog overhaul still
    # clears its discontinued homes without anyone stepping in.
    MASS_REMOVAL_HOLD = 21.days

    Result = Struct.new(:added, :updated, :unchanged, :inactivated, :held, keyword_init: true)

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
        video_url:         home.video_url,
        building_code:     building_code_for(home, source)
      }
    end

    # What the listing says (Cavco's building method, Adventure's HUD/MOD/ANSI),
    # else the source's default_building_code for a builder whose site never
    # says because it builds only one kind (Kabco: HUD).
    def self.building_code_for(home, source)
      BuildingCode.from_labels(home.property_type) ||
        BuildingCode.from_label(source&.config.is_a?(Hash) ? source.config['default_building_code'] : nil)
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
    # @param not_wanted [Array<String>] keys the crawl saw that this dealer
    #   does not carry (DealerCatalogSubscription#wants?). They are not
    #   missing, so they never count toward the mass-removal hold: their rows
    #   come off now, unless the dealer has done work on one.
    # @return [Result]
    def call(homes, not_wanted: [])
      result    = Result.new(added: 0, updated: 0, unchanged: 0, inactivated: 0, held: 0)
      seen_keys = []

      homes.each do |home|
        seen_keys << home.source_key.to_s
        case upsert(home)
        when :added     then result.added += 1
        when :updated   then result.updated += 1
        when :unchanged then result.unchanged += 1
        end
      end

      not_wanted = not_wanted.map(&:to_s)
      result.inactivated += remove_not_wanted(not_wanted)
      inactivate_missing(seen_keys + not_wanted, result)
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
        columns = { catalog_last_seen_at: Time.current, is_deleted: false, deleted_at: nil }
        # content_hash is computed from SOURCE urls, deliberately, so rehosting
        # imagery never looks like a content change. The flip side is that an
        # otherwise-unchanged home takes this branch and would throw away the
        # local_url the archiver just produced — one Kabco run archived 184
        # images and persisted none of them. Carry them through.
        columns.merge!(rehosted_columns(vehicle, home))
        vehicle.update_columns(columns)
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

    def inactivate_missing(seen_keys, result)
      # A run with no homes at all says the crawl failed, not that a manufacturer
      # discontinued its whole catalog. Treating it as the latter soft-deleted
      # every home on every subscribed dealer during any site outage or block.
      return if seen_keys.empty?

      # Scoped to THIS location so ingesting one location doesn't tombstone
      # another location's copies.
      scope = @company.vehicles
                      .where(catalog_source_id: @source.id, location_id: @location_id, is_deleted: [false, nil])

      missing = scope.where.not(catalog_source_key: seen_keys).select { |vehicle| removable?(vehicle) }
      present = scope.where(catalog_source_key: seen_keys).count

      # Losing most of a catalog in one run usually means the crawl died partway.
      # Hold those homes and let the run report it; each is released once it has
      # gone unseen for the whole hold, which is what a real overhaul looks like.
      if missing.size > present
        cutoff = MASS_REMOVAL_HOLD.ago
        expired, held = missing.partition { |v| v.catalog_last_seen_at && v.catalog_last_seen_at < cutoff }
        missing = expired
        result.held = held.size
        Rails.logger.warn "[Catalog::IngestionService] holding #{held.size} homes for company #{@company.id}, " \
                          "source #{@source.id}: only #{present} seen this run"
      end

      missing.each { |vehicle| vehicle.update_columns(is_deleted: true, deleted_at: Time.current) }
      result.inactivated += missing.size
    end

    # Rows of homes the dealer left out (or has not decided on, while new
    # homes are held). Same protection as a home leaving the feed: one the
    # dealer has worked on stays. Ticking the home back restores the row on
    # the next ingest (upsert finds it and clears is_deleted).
    def remove_not_wanted(keys)
      return 0 if keys.empty?

      rows = @company.vehicles.where(catalog_source_id: @source.id, location_id: @location_id, is_deleted: [false, nil],
                                     catalog_source_key: keys).select { |vehicle| removable?(vehicle) }
      rows.each { |vehicle| vehicle.update_columns(is_deleted: true, deleted_at: Time.current) }
      rows.size
    end

    def removable?(vehicle)
      # Never tombstone a supplemented vehicle — it's a dealer-original row that
      # we attached catalog data to. Catalog dropping the model just means the
      # dealer keeps it as-is.
      return false if self.class.supplemented?(vehicle)

      # Nor a seeded inventory row. Those are the dealer's own homes, imported
      # once at onboarding; a floorplan run must not tombstone them, and a home
      # leaving the manufacturer's index does not un-sell it.
      return false if vehicle.source == SEEDED_VEHICLE_SOURCE

      # Nor a home the dealer has done work on: on a deal or quote, listed, has
      # an edited copy, given a status, or priced. Sync never writes status or
      # price, so either one was the dealer. The Champion sync keeps these too.
      !(vehicle.has_dealer_activity? ||
        vehicle.status != 'available_to_order' ||
        vehicle.sale_price.to_f.positive?)
    end

    # Columns to rewrite when the ONLY thing that moved is where an image is
    # hosted. Returns {} when nothing was rehosted, so an unchanged home stays a
    # single cheap update. Photos a dealer added, removed, reordered or picked as
    # the cover stay exactly as they are: this only swaps a URL for our own copy
    # of the same picture. What it writes is also recorded as last synced, or the
    # copy would read as a dealer edit on the next real change.
    def rehosted_columns(vehicle, home)
      synced  = vehicle.catalog_last_synced_values || {}
      columns = {}
      record  = {}

      gallery = self.class.url_images(gallery_images_for(home))
      plans   = self.class.url_images(home.floorplan_images)

      { images: gallery, floor_plan_images: plans }.each do |field, incoming|
        next if incoming.empty?

        current = url_list(vehicle.public_send(field))
        prior   = url_list(synced[field.to_s])
        next unless catalog_media?(current, prior, url_list(incoming))

        columns[field] = incoming if current != url_list(incoming)
        record[field.to_s] = incoming if prior != url_list(incoming)
      end

      primary = gallery.first&.dig('url')
      if primary.present? && catalog_cover?(vehicle, synced, gallery)
        columns[:photo_url] = primary if vehicle.photo_url != primary
        record['photo_url'] = primary if synced['photo_url'] != primary
      end

      columns[:catalog_last_synced_values] = synced.merge(record) if record.any?
      columns
    end

    # True when these photos are still the catalog's: what we last synced, or
    # the same pictures in the same places with some now on our own copies. Rows
    # rehosted before last-synced was recorded land in the second case.
    def catalog_media?(current, prior, incoming)
      return true if current == prior
      return false if current.size != incoming.size

      current.each_with_index.all? { |url, i| url == incoming[i] || url == prior[i] }
    end

    def catalog_cover?(vehicle, synced, gallery)
      cover = vehicle.photo_url
      return true if cover.blank? || cover == synced['photo_url'] || cover == gallery.first&.dig('url')
      return false unless url_list(vehicle.images).first == cover

      catalog_media?(url_list(vehicle.images), url_list(synced['images']), url_list(gallery))
    end

    # Mirrors catalog_attrs_from's gallery choice so the two cannot diverge.
    def gallery_images_for(home)
      gallery = home.images.reject { |i| (i['is_floorplan'] == true) || (i['is_floorplan'].to_s == 'true') }
      gallery.presence || home.images
    end

    def url_list(images)
      Array(images).map { |i| i.is_a?(Hash) ? (i['url'] || i['source_url']) : i }
    end

    # The building code joins the scraped content: a code can come from the
    # source's default_building_code rather than the listing, and setting that
    # default changes nothing scraped, so homes already in stock never got it.
    def content_signature(home)
      code = self.class.building_code_for(home, @source)
      "v#{INGESTION_VERSION}:#{home.content_hash}#{":#{code}" if code}"
    end

    # A source's name is an operator's label, not a manufacturer — see
    # Catalog::ManufacturerName, which is shared with the Cavco seeder because
    # both wrote the same wrong thing onto a listing card.
    def manufacturer_name
      Catalog::ManufacturerName.for(@source)
    end
  end
end
