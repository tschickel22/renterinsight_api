# frozen_string_literal: true

module Scrapers
  # Syncs Champion IMS feed data for a single ChampionImsRetailer directly into
  # the dealer's Vehicle inventory as CATALOG ROWS (source='champion_ims').
  #
  # ARCHITECTURE (revised 2026-04-15 per Tom's spec)
  # ------------------------------------------------
  # Catalog rows are immutable to dealers and synced fresh every run. When a
  # dealer changes a catalog row's status (other than 'available_to_order'),
  # the system clones it via VehicleCloneFromCatalogService rather than
  # editing in place. The catalog row stays pristine.
  #
  # WRITE BEHAVIOR
  # --------------
  # - This service ONLY writes to rows where source='champion_ims'.
  # - It NEVER touches rows where source='champion_ims_clone' (dealer property).
  # - Status is forced back to 'available_to_order' on every sync. Defensive:
  #   if anything else has mutated a catalog row's status, sync corrects it.
  # - Full upsert: every whitelisted-extracted attribute is overwritten.
  #
  # MULTI-LOCATION SUPPORT (Option C)
  # ---------------------------------
  # If retailer.apply_to_all_locations is true, vehicles get location_id=nil
  # (visible across all locations). Otherwise vehicles inherit
  # retailer.location_id (which may also be nil for legacy retailers).
  #
  # TOMBSTONING
  # -----------
  # Catalog rows that haven't been seen in the feed for TOMBSTONE_AGE get
  # soft-deleted, EXCEPT when they have dealer activity (clones, deals,
  # quotes, listings, packages). Those stay as historical references even
  # if Champion drops the model.
  #
  # FEED HISTORY
  # ------------
  # Every invocation creates a ChampionImsSyncRun row with status='running'
  # at the start, then records a ChampionImsSyncEvent row for each home
  # touched (added / updated / unchanged / tombstoned / protected / skipped),
  # finally updating the run row to its terminal status with all counters.
  # See ChampionImsSyncRun and ChampionImsSyncEvent for the schema.
  #
  # Usage:
  #   retailer = ChampionImsRetailer.find_by(retailer_navision_id: '0551KS')
  #   stats    = Scrapers::ChampionImsSyncService.new(retailer, trigger: 'manual').call
  #   # => { catalog_added: 12, catalog_updated: 3, catalog_unchanged: 35,
  #   #      catalog_tombstoned: 1, catalog_protected: 5, vehicles_skipped: 0,
  #   #      total: 50, duration_ms: 4231 }
  class ChampionImsSyncService
    SOURCE_KEY            = 'champion_ims'
    DEFAULT_LISTING_TYPE  = 'manufactured_home'
    DEFAULT_HOME_TYPE     = 'hud'
    DEFAULT_MAKE          = 'Champion Homes'
    CATALOG_STATUS        = 'available_to_order'
    TOMBSTONE_AGE         = 14.days

    # Vehicle attributes that are noisy, internal, or sync-bookkeeping. We
    # exclude them from the per-event diff so the history view shows only
    # changes a dealer would care about (model name, beds, sqft, etc.).
    UNINTERESTING_DIFF_KEYS = %w[
      updated_at
      champion_last_seen_at
      champion_raw_payload
      champion_images
      images
      floor_plan_images
      elevation_images
      photo_url
      source
      status
      listing_type
      condition
      location_id
      is_deleted
      serial_number
      year
      home_type
      inventory_id
      matterport_url
      virtual_tour_url
      video_url
      champion_pdp_url
      champion_series_name
      champion_brand_name
      champion_brand_logo_url
    ].freeze

    # Champion's "type" field → number of sections we store on the vehicle.
    SECTIONS_BY_TYPE = {
      'singlesection' => 1,
      'multisection'  => 2,
      'triplesection' => 3
    }.freeze

    attr_reader :retailer, :company, :stats, :sync_run, :trigger

    def initialize(retailer, trigger: 'manual')
      @retailer = retailer
      @company  = retailer.company
      @trigger  = trigger.to_s
      @stats    = {
        catalog_added:      0,
        catalog_updated:    0,
        catalog_unchanged:  0,
        catalog_tombstoned: 0,
        catalog_protected:  0, # would-be tombstoned but had dealer activity
        vehicles_skipped:   0,
        total:              0,
        duration_ms:        0
      }
      @sync_run = nil
    end

    def call
      started_at = Time.current
      mark_running!
      create_sync_run!(started_at)

      Rails.logger.info "[ChampionImsSync] START #{retailer.display_label} " \
        "(apply_to_all_locations=#{retailer.apply_to_all_locations}, location_id=#{retailer.location_id}, trigger=#{trigger})"

      client = ChampionImsClient.new(navision_id: retailer.retailer_navision_id)
      homes  = client.fetch_all

      if homes.nil? || homes.empty?
        Rails.logger.warn "[ChampionImsSync] No homes returned from feed for #{retailer.display_label}"
        mark_success!(started_at)
        return stats
      end

      Rails.logger.info "[ChampionImsSync] Feed returned #{homes.size} home(s)"

      ActiveRecord::Base.transaction do
        homes.each do |home_data|
          upsert_catalog_vehicle(home_data, client)
        end
        tombstone_stale_catalog_vehicles!
      end

      mark_success!(started_at)
      Rails.logger.info "[ChampionImsSync] DONE #{retailer.display_label} stats=#{stats.inspect}"
      stats
    rescue StandardError => e
      Rails.logger.error "[ChampionImsSync] FAILED for #{retailer.display_label}: #{e.class}: #{e.message}"
      Rails.logger.error e.backtrace.first(10).join("\n")
      mark_failed!(e, started_at)
      raise if Rails.env.development?
      stats
    end

    private

    # ------------------------------------------------------------------
    # Catalog vehicle upsert (CREATE or full UPDATE)
    # ------------------------------------------------------------------
    def upsert_catalog_vehicle(home_data, client)
      champion_model_id = extract_model_id(home_data)
      if champion_model_id.blank?
        Rails.logger.warn "[ChampionImsSync] Skipping home without id: #{home_data.inspect.truncate(200)}"
        stats[:vehicles_skipped] += 1
        record_event!(
          event_type:        'skipped',
          champion_model_id: nil,
          display_name:      extract_display_name(home_data),
          reason:            'Feed entry missing id/modelId field'
        )
        return
      end

      vehicle = company.vehicles.find_or_initialize_by(
        source:            SOURCE_KEY,
        champion_model_id: champion_model_id
      )

      is_new = vehicle.new_record?
      apply_attrs!(vehicle, home_data, client, is_new: is_new)

      if vehicle.save
        stats[:total] += 1

        # `saved_changes` reflects what was actually persisted (post-callbacks).
        # Using `vehicle.changes` BEFORE save would include normalizations that
        # later get reverted by `before_validation` callbacks — a real-world
        # example was Vehicle#normalize_fields titleizing model names back to
        # their previous form, producing phantom "updated" events forever.
        post_save_changes = filtered_changes(vehicle.saved_changes)

        if is_new
          stats[:catalog_added] += 1
          record_event!(
            event_type:        'added',
            vehicle:           vehicle,
            champion_model_id: champion_model_id
          )
        elsif post_save_changes.empty?
          stats[:catalog_unchanged] += 1
          record_event!(
            event_type:        'unchanged',
            vehicle:           vehicle,
            champion_model_id: champion_model_id
          )
        else
          stats[:catalog_updated] += 1
          record_event!(
            event_type:        'updated',
            vehicle:           vehicle,
            champion_model_id: champion_model_id,
            field_changes:     post_save_changes
          )
        end
      else
        stats[:vehicles_skipped] += 1
        error_msg = vehicle.errors.full_messages.join(', ')
        Rails.logger.warn(
          "[ChampionImsSync] FAILED to save catalog vehicle champion_model_id=#{champion_model_id}: " \
          "#{error_msg} | data=#{home_data.inspect.truncate(300)}"
        )
        record_event!(
          event_type:        'skipped',
          champion_model_id: champion_model_id,
          display_name:      extract_display_name(home_data),
          reason:            "Validation failed: #{error_msg}"
        )
      end
    end

    # Convert AR Dirty's `{field => [from, to]}` shape into the jsonb shape
    # the events table stores: `{field => {"from" => from, "to" => to}}`.
    # Filters out uninteresting fields (timestamps, raw payloads, sync-bookkeeping).
    # Also filters semantically-equivalent changes that AR sometimes flags after
    # type coercion (e.g. "3" -> 3, BigDecimal("2.0") -> 2.0, nil -> "").
    def filtered_changes(raw_changes)
      raw_changes.each_with_object({}) do |(field, (from_val, to_val)), out|
        next if UNINTERESTING_DIFF_KEYS.include?(field)
        next if values_semantically_equal?(from_val, to_val)
        out[field] = { 'from' => from_val, 'to' => to_val }
      end
    end

    # Returns true when two values represent the same logical content even if
    # their classes differ. AR Dirty fires on assignment of "3" to an integer
    # column already holding 3, on BigDecimal("2.0") vs 2.0, on nil vs "", etc.
    # This guards against those false positives without losing real diffs.
    def values_semantically_equal?(a, b)
      return true if a == b
      return true if a.nil? && b.to_s.empty?
      return true if b.nil? && a.to_s.empty?
      # Numeric coercion: "3" == 3, BigDecimal("2") == 2, etc.
      if a.is_a?(Numeric) || b.is_a?(Numeric)
        a_num = numeric_or_nil(a)
        b_num = numeric_or_nil(b)
        return a_num == b_num if a_num && b_num
      end
      # String comparison as last resort (handles BigDecimal("2.0").to_s == "2.0"
      # vs Float(2.0).to_s == "2.0" parity)
      a.to_s == b.to_s
    end

    def numeric_or_nil(value)
      case value
      when Numeric  then value
      when String   then (Float(value) rescue nil)
      else nil
      end
    end

    # Full upsert: writes ALL extractable fields. Catalog rows are sync-owned.
    # Dealer edits to catalog rows are not preserved (and shouldn't exist —
    # the controller should reject in-place edits and require cloning instead).
    def apply_attrs!(vehicle, home_data, client, is_new:)
      attrs = build_full_attrs(home_data, client)
      vehicle.assign_attributes(attrs)

      # Always-applied catalog defaults — these are corrected on every sync to
      # keep catalog rows in their canonical state.
      vehicle.source          = SOURCE_KEY
      vehicle.status          = CATALOG_STATUS  # force back to available_to_order
      vehicle.listing_type    = DEFAULT_LISTING_TYPE
      vehicle.condition     ||= 'new'
      vehicle.location_id     = resolve_location_id  # respect apply_to_all_locations
      vehicle.year          ||= Date.current.year   # IMS feed has no year
      vehicle.serial_number ||= "CHAMP-#{vehicle.champion_model_id}" # MH validation requires presence
      vehicle.is_deleted      = false
      # inventory_id auto-generated by Vehicle's before_validation callback on create
    end

    # All field values from the IMS feed payload, enriched with whatever the
    # PDP scrape returns. The feed's 4-image carousel is only a teaser — when
    # the PDP yields a fuller gallery we use that instead, and we attach the
    # Matterport tour, walkthrough video, and elevation renderings that the
    # feed never exposes.
    def build_full_attrs(home_data, client)
      gallery, floor_plans = partition_images(home_data)
      slug = home_data['slug'].to_s.strip

      attrs = {
        make:                    extract_make(home_data),
        model:                   extract_model(home_data),
        bedrooms:                to_int(home_data['numberOfBeds']),
        bathrooms:               to_decimal(home_data['numberOfBaths']),
        square_feet:             to_int(home_data['squareFeet']),
        sections:                extract_sections(home_data),
        home_type:               extract_home_type(home_data),
        champion_pdp_url:        slug.empty? ? nil : "#{ChampionImsClient::PDP_BASE_URL}/#{slug}",
        champion_series_name:    home_data['seriesName'].presence,
        champion_brand_name:     extract_brand_name(home_data),
        champion_brand_logo_url: extract_brand_logo_url(home_data),
        # Champion-owned audit columns (raw + timestamps)
        champion_images:         gallery + floor_plans,
        champion_raw_payload:    home_data,
        champion_last_seen_at:   Time.current,
        # Dealer-facing display columns (what the UI actually reads)
        images:                  gallery,
        floor_plan_images:       floor_plans,
        photo_url:               gallery.first&.dig('url')
      }

      # PDP enrichment — replace feed media with the fuller set when available.
      # Silent no-op on any PDP failure so sync never breaks on scraping issues.
      if slug.present? && client
        pdp_media = client.fetch_pdp_media(slug)
        if pdp_media[:gallery].any?
          attrs[:images]    = pdp_media[:gallery].map { |url| { 'url' => url } }
          attrs[:photo_url] = pdp_media[:gallery].first
        end
        if pdp_media[:matterport_url].present?
          attrs[:matterport_url]   = pdp_media[:matterport_url]
          attrs[:virtual_tour_url] = pdp_media[:matterport_url]
        end
        attrs[:video_url] = pdp_media[:video_url] if pdp_media[:video_url].present?
        if pdp_media[:floor_plans].any?
          attrs[:floor_plan_images] = pdp_media[:floor_plans].map { |url| { 'url' => url } }
        end
        if pdp_media[:elevations].any?
          attrs[:elevation_images] = pdp_media[:elevations].map { |url| { 'url' => url } }
        end
      end

      attrs.compact
    end

    def extract_sections(home_data)
      key = home_data['type'].to_s.downcase.delete(' ')
      SECTIONS_BY_TYPE[key]
    end

    def extract_home_type(home_data)
      code = home_data.dig('buildingCode', 'code').to_s.downcase
      code.presence || DEFAULT_HOME_TYPE
    end

    def extract_brand_name(home_data)
      home_data.dig('brandDetails', 'title').presence || home_data['factoryBrand'].presence
    end

    def extract_brand_logo_url(home_data)
      logo = home_data.dig('brandDetails', 'logo').to_s.strip
      return nil if logo.empty?
      return logo if logo.start_with?('http://', 'https://')
      "https://www.championhomes.com#{logo.start_with?('/') ? logo : "/#{logo}"}"
    end

    # Partition Champion's `images` array into gallery photos vs floor plans
    # based on the alt text. Champion's alt text reliably contains "floor plan"
    # (case-insensitive) for floor plan assets.
    #   Returns [[{url, alt}, ...], [{url, alt}, ...]]  ->  [gallery, floor_plans]
    def partition_images(home_data)
      raw = home_data['images']
      return [[], []] unless raw.is_a?(Array)

      normalized = raw.filter_map do |img|
        next unless img.is_a?(Hash)
        url = img['path']
        next if url.blank?
        { 'url' => url, 'alt' => img['alt'] }.compact
      end

      floor_plans, gallery = normalized.partition do |img|
        alt = img['alt'].to_s.downcase
        alt.include?('floor plan') || alt.include?('floorplan')
      end

      [gallery, floor_plans]
    end

    # Resolve location_id based on retailer settings:
    #   - apply_to_all_locations: true  -> nil (company-wide visibility)
    #   - apply_to_all_locations: false -> retailer.location_id (may be nil)
    def resolve_location_id
      return nil if retailer.apply_to_all_locations
      retailer.location_id
    end

    # ------------------------------------------------------------------
    # Tombstoning
    # ------------------------------------------------------------------
    # Soft-delete catalog rows that haven't been seen in TOMBSTONE_AGE.
    # PROTECT catalog rows that have dealer activity (clones, deals, quotes,
    # listings, packages) — those stay as historical references.
    def tombstone_stale_catalog_vehicles!
      cutoff = TOMBSTONE_AGE.ago

      stale_scope = company.vehicles
                           .where(source: SOURCE_KEY, is_deleted: false)
                           .where('champion_last_seen_at IS NULL OR champion_last_seen_at < ?', cutoff)

      # Scope to this retailer's location bucket
      if retailer.apply_to_all_locations
        stale_scope = stale_scope.where(location_id: nil)
      elsif retailer.location_id.present?
        stale_scope = stale_scope.where(location_id: retailer.location_id)
      end
      # If retailer has no location_id and is not apply_to_all_locations, only
      # tombstone vehicles with the same nil location_id (legacy behavior).

      stale_scope.find_each do |v|
        if v.has_dealer_activity?
          stats[:catalog_protected] += 1
          Rails.logger.info(
            "[ChampionImsSync] PROTECTED catalog vehicle ##{v.id} (#{v.inventory_id}) " \
            "from tombstone — has dealer activity"
          )
          record_event!(
            event_type:        'protected',
            vehicle:           v,
            champion_model_id: v.champion_model_id,
            reason:            'Has dealer activity (clones/deals/quotes/listings) — kept as historical reference'
          )
          next
        end

        v.update_columns(is_deleted: true, deleted_at: Time.current)
        stats[:catalog_tombstoned] += 1
        record_event!(
          event_type:        'tombstoned',
          vehicle:           v,
          champion_model_id: v.champion_model_id,
          reason:            "Not seen in feed since #{v.champion_last_seen_at&.iso8601 || 'creation'}"
        )
      end
    end

    # ------------------------------------------------------------------
    # Field extractors
    # ------------------------------------------------------------------
    def extract_model_id(home_data)
      return nil unless home_data.is_a?(Hash)
      %w[id modelId model_id uuid].each do |key|
        value = home_data[key]
        return value.to_s.strip if value.present?
      end
      nil
    end

    def extract_make(home_data)
      home_data['factoryBrand'].presence || DEFAULT_MAKE
    end

    def extract_model(home_data)
      home_data['name'].presence || 'Unnamed Model'
    end

    # Best-effort display name for events when a vehicle could not be created.
    def extract_display_name(home_data)
      return 'Unknown' unless home_data.is_a?(Hash)
      [extract_make(home_data), extract_model(home_data)].compact.join(' ').strip.presence || 'Unknown'
    end

    # Legacy single-list extractor kept for any callers that still need the
    # combined list. Sync now uses `partition_images` instead.
    def extract_images(home_data)
      gallery, floor_plans = partition_images(home_data)
      gallery + floor_plans
    end

    def to_int(value)
      return nil if value.blank?
      Integer(value.to_s.gsub(/[^\d-]/, ''))
    rescue ArgumentError, TypeError
      nil
    end

    def to_decimal(value)
      return nil if value.blank?
      BigDecimal(value.to_s.gsub(/[^\d.-]/, ''))
    rescue ArgumentError, TypeError
      nil
    end

    # ------------------------------------------------------------------
    # Sync run / event tracking
    # ------------------------------------------------------------------
    def create_sync_run!(started_at)
      @sync_run = ChampionImsSyncRun.create!(
        company:               company,
        champion_ims_retailer: retailer,
        status:                'running',
        started_at:            started_at,
        trigger:               trigger
      )
    rescue StandardError => e
      # Don't let history failures break sync — log and continue with sync_run=nil
      Rails.logger.error "[ChampionImsSync] Failed to create sync_run: #{e.class}: #{e.message}"
      @sync_run = nil
    end

    # Persist an event row. Failures are logged loudly with a backtrace —
    # we don't want event-write bugs to silently corrupt history (this is
    # exactly how the field_changes column collision went undetected).
    def record_event!(event_type:, vehicle: nil, champion_model_id: nil, display_name: nil, field_changes: {}, reason: nil)
      return unless sync_run

      ChampionImsSyncEvent.create!(
        champion_ims_sync_run: sync_run,
        vehicle:               vehicle,
        champion_model_id:     champion_model_id,
        event_type:            event_type,
        display_name:          display_name || vehicle_display_name(vehicle),
        inventory_id:          vehicle&.inventory_id,
        field_changes:         field_changes || {},
        reason:                reason
      )
    rescue StandardError => e
      Rails.logger.error "[ChampionImsSync] Failed to record event #{event_type}: #{e.class}: #{e.message}"
      Rails.logger.error e.backtrace.first(8).join("\n")
    end

    def vehicle_display_name(vehicle)
      return nil unless vehicle
      [vehicle.year, vehicle.make, vehicle.model].compact.join(' ').strip.presence
    end

    # ------------------------------------------------------------------
    # Retailer status tracking
    # ------------------------------------------------------------------
    def mark_running!
      retailer.update!(
        last_sync_status: 'running',
        last_sync_error:  nil
      )
    end

    def mark_success!(started_at)
      stats[:duration_ms] = ((Time.current - started_at) * 1000).round
      next_at = retailer.sync_frequency == 'weekly' ? 7.days.from_now : nil

      retailer.update!(
        last_sync_status:       'success',
        last_sync_at:           Time.current,
        last_sync_error:        nil,
        last_sync_stats:        stats.stringify_keys,
        next_scheduled_sync_at: next_at
      )

      finalize_sync_run!('success', nil)
    end

    def mark_failed!(error, started_at)
      stats[:duration_ms] = ((Time.current - started_at) * 1000).round

      retailer.update!(
        last_sync_status: 'failed',
        last_sync_at:     Time.current,
        last_sync_error:  "#{error.class}: #{error.message}",
        last_sync_stats:  stats.stringify_keys
      )

      finalize_sync_run!('failed', "#{error.class}: #{error.message}")
    end

    # Update the sync_run row with terminal status and all counters.
    # Best-effort: failures here are logged but don't propagate.
    def finalize_sync_run!(status, error_message)
      return unless sync_run

      sync_run.update!(
        status:             status,
        finished_at:        Time.current,
        duration_ms:        stats[:duration_ms],
        catalog_added:      stats[:catalog_added],
        catalog_updated:    stats[:catalog_updated],
        catalog_unchanged:  stats[:catalog_unchanged],
        catalog_tombstoned: stats[:catalog_tombstoned],
        catalog_protected:  stats[:catalog_protected],
        vehicles_skipped:   stats[:vehicles_skipped],
        total:              stats[:total],
        error_message:      error_message
      )
    rescue StandardError => e
      Rails.logger.error "[ChampionImsSync] Failed to finalize sync_run: #{e.class}: #{e.message}"
    end
  end
end
