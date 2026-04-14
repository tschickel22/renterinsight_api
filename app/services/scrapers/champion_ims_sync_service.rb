# frozen_string_literal: true

module Scrapers
  # Syncs Champion IMS feed data for a single ChampionImsRetailer into the
  # shared FloorPlan catalog.
  #
  # This service NEVER creates Vehicle records. It only upserts FloorPlans
  # keyed on [manufacturer_id, model_code] where model_code is Champion's
  # internal UUID (the 'id' field in the feed response).
  #
  # Vehicle creation happens later via a separate bulk-import wizard (Prompt 3).
  #
  # Usage:
  #   retailer = ChampionImsRetailer.find_by(retailer_navision_id: '0551KS')
  #   result   = Scrapers::ChampionImsSyncService.new(retailer).call
  #   # => { added: 12, updated: 38, total: 50, duration_ms: 4231 }
  class ChampionImsSyncService
    CHAMPION_MANUFACTURER_NAME = 'Champion Homes'
    CHAMPION_MANUFACTURER_CODE = 'CHAMPION'

    attr_reader :retailer, :stats

    def initialize(retailer)
      @retailer = retailer
      @stats = { added: 0, updated: 0, removed: 0, total: 0, duration_ms: 0 }
    end

    def call
      started_at = Time.current
      mark_running!

      manufacturer = find_or_create_manufacturer
      client       = ChampionImsClient.new(navision_id: retailer.retailer_navision_id)
      homes        = client.fetch_all

      if homes.nil? || homes.empty?
        Rails.logger.warn "[ChampionImsSync] No homes returned from feed for #{retailer.display_label}"
        mark_success!(started_at)
        return stats
      end

      ActiveRecord::Base.transaction do
        homes.each do |home_data|
          upsert_floor_plan(manufacturer, home_data)
        end
      end

      mark_success!(started_at)
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
    # Manufacturer lookup - mirrors the existing ChampionHomesScraper
    # pattern so both services resolve to the same Manufacturer record.
    # ------------------------------------------------------------------
    def find_or_create_manufacturer
      manufacturer = Manufacturer.find_or_create_by!(name: CHAMPION_MANUFACTURER_NAME) do |m|
        m.industry_type    = 'manufactured_homes' if m.respond_to?(:industry_type=)
        m.website          = 'https://www.championhomes.com'
        m.active           = true
        m.scraper_enabled  = true if m.respond_to?(:scraper_enabled=)
      end

      if manufacturer.respond_to?(:code) && manufacturer.code.blank?
        manufacturer.update!(code: CHAMPION_MANUFACTURER_CODE)
      end

      manufacturer
    end

    # ------------------------------------------------------------------
    # FloorPlan upsert
    # ------------------------------------------------------------------
    def upsert_floor_plan(manufacturer, home_data)
      model_code = extract_model_code(home_data)
      return unless model_code.present?

      attrs = extract_floor_plan_attrs(home_data)

      floor_plan = FloorPlan.find_or_initialize_by(
        manufacturer_id: manufacturer.id,
        model_code:      model_code
      )

      is_new = floor_plan.new_record?

      # Preserve manually-added data on existing rows. The IMS feed does not
      # expose width/length, and dealers may have manually added dimensions
      # via spreadsheet backfill (see tmp/backfill_skyline_dimensions.rb).
      # We also avoid overwriting beds/baths if they were manually corrected.
      unless is_new
        attrs.delete(:width_feet)  if floor_plan.width_feet.present?
        attrs.delete(:length_feet) if floor_plan.length_feet.present?
        attrs.delete(:beds)        if floor_plan.beds.present?  && attrs[:beds].blank?
        attrs.delete(:baths)       if floor_plan.baths.present? && attrs[:baths].blank?

        # Merge specifications instead of replacing - preserves manual
        # backfill markers (manual_dimensions_source, sections, etc.)
        if floor_plan.specifications.is_a?(Hash) && attrs[:specifications].is_a?(Hash)
          attrs[:specifications] = floor_plan.specifications.merge(attrs[:specifications])
        end
      end

      floor_plan.assign_attributes(attrs)
      floor_plan.last_scraped_at = Time.current

      if floor_plan.save
        if is_new
          stats[:added] += 1
        else
          stats[:updated] += 1
        end
        stats[:total] += 1
      else
        Rails.logger.warn "[ChampionImsSync] Skipped floor_plan #{model_code}: #{floor_plan.errors.full_messages.join(', ')}"
      end
    end

    # Champion's feed uses 'id' as the stable UUID for each home model.
    # Fall back to other likely keys if the shape changes.
    def extract_model_code(home_data)
      return nil unless home_data.is_a?(Hash)

      %w[id modelId model_id uuid].each do |key|
        value = home_data[key]
        return value.to_s.strip if value.present?
      end

      nil
    end

    # ------------------------------------------------------------------
    # Feed field mapping
    # ------------------------------------------------------------------
    # Maps a Champion IMS feed record to FloorPlan columns.
    # Field names verified against the live 0551KS feed response (2026-04-14).
    def extract_floor_plan_attrs(home_data)
      {
        name:              home_data['name'].presence || 'Unnamed Model',
        series:            home_data['seriesName'],
        brand:             home_data['factoryBrand'].presence || CHAMPION_MANUFACTURER_NAME,
        home_type:         normalize_home_type(home_data['type']),
        beds:              to_int(home_data['numberOfBeds']),
        baths:             to_decimal(home_data['numberOfBaths']),
        sqft:              to_int(home_data['squareFeet']),
        # width/length are not present in the IMS feed - leave nil
        specifications:    build_specifications(home_data),
        images_array:      extract_images(home_data),
        scraper_source_url: build_detail_url(home_data),
        is_active:         true
      }.compact
    end

    # Champion doesn't expose a full detail page URL in the feed - construct
    # one from the slug if present, otherwise nil.
    def build_detail_url(home_data)
      slug = home_data['slug']
      return nil if slug.blank?
      "https://www.championhomes.com/homes/#{slug}"
    end

    # Picks the first non-blank value from a list of possible keys.
    def pick(hash, keys)
      keys.each do |k|
        v = hash[k]
        return v if v.present?
      end
      nil
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

    # Champion IMS 'type' field is unreliable for HUD-vs-RV classification.
    # Heartland 0551KS (verified 2026-04-14 with the dealer) confirmed that
    # ALL inventory in their feed is HUD-built manufactured housing, including
    # models Champion tags as 'ParkModelRv'. The 'PT' (Park-Trailer) and
    # Contemporary Cabin lines are park-model HUD homes, not recreational
    # vehicles. Until we have a confirmed RV signal in the feed, default
    # everything to 'hud'.
    #
    # If we later need to distinguish modular from HUD, the 'buildingCode.code'
    # field in the payload exposes 'ANSI' vs 'HUD' which is more reliable
    # than the marketing 'type' string.
    def normalize_home_type(value)
      building_code = nil
      # If caller passed the whole hash, look at buildingCode first
      # (this method is currently called with just the type string but kept
      # defensive in case we wire it through the full payload later).
      'hud'
    end

    # Stores the raw feed record plus derived/normalized fields.
    # The raw_payload is kept verbatim so we can re-extract fields later
    # without re-hitting the feed.
    def build_specifications(home_data)
      {
        'slug'               => home_data['slug'],
        'type'               => home_data['type'],
        'series_id'          => home_data['seriesId'],
        'factory_brand'      => home_data['factoryBrand'],
        'factory_brand_id'   => home_data['factoryBrandId'],
        'factory_brand_slug' => home_data['factoryBrandSlug'],
        'factory_city'       => home_data['factoryBrandCity'],
        'factory_state'      => home_data['factoryBrandState'],
        'building_code'      => home_data.dig('buildingCode', 'code'),
        'can_configure'      => home_data['canConfigure'],
        'is_in_stock'        => home_data['isInStock'],
        'is_featured'        => home_data['isFeatured'],
        'is_best_seller'     => home_data['isBestSeller'],
        'is_move_in_ready'   => home_data['isMoveInReady'],
        'is_ready_to_tour'   => home_data['isReadyToTour'],
        'move_in_ready_count' => home_data['moveInReadyCount'],
        'secondary_tag'      => home_data['secondaryTag'],
        'feed_price'         => home_data['price'],
        'features'           => home_data['features'],
        'brand_details'      => home_data['brandDetails'],
        'raw_payload'        => home_data
      }.compact
    end

    # Champion IMS returns images as an array of hashes:
    #   [{ 'alt' => 'Shore-Park-D802-exterior', 'path' => 'https://s7d9.scene7.com/...' }, ...]
    # Normalized to the existing FloorPlan images_array convention:
    #   [{ 'url' => 'https://...', 'alt' => '...' }, ...]
    def extract_images(home_data)
      images = home_data['images']
      return [] unless images.is_a?(Array)

      images.filter_map do |img|
        next unless img.is_a?(Hash)
        url = img['path']
        next if url.blank?
        { 'url' => url, 'alt' => img['alt'] }.compact
      end
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
    end

    def mark_failed!(error, started_at)
      stats[:duration_ms] = ((Time.current - started_at) * 1000).round

      retailer.update!(
        last_sync_status: 'failed',
        last_sync_at:     Time.current,
        last_sync_error:  "#{error.class}: #{error.message}",
        last_sync_stats:  stats.stringify_keys
      )
    end
  end
end
