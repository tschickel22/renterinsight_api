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

    Result = Struct.new(:added, :updated, :unchanged, :inactivated, keyword_init: true)

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
      vehicle = @company.vehicles.find_or_initialize_by(
        catalog_source_id:  @source.id,
        catalog_source_key: home.source_key.to_s
      )
      is_new = vehicle.new_record?

      # Unchanged: same content hash on an existing row → just refresh last-seen.
      if !is_new && vehicle.catalog_content_hash == home.content_hash
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
      gallery   = home.images
      floor_pl  = home.floorplan_images
      primary   = gallery.find { |i| !i['is_floorplan'] } || gallery.first

      attrs = {
        listing_type:         'manufactured_home',
        source:               VEHICLE_SOURCE,
        status:               'available_to_order',
        condition:            'new',
        make:                 manufacturer_name,
        model:                home.model_name,
        bedrooms:             home.bedrooms,
        bathrooms:            home.bathrooms,
        square_feet:          home.square_feet,
        description:          home.description,
        images:               gallery,
        floor_plan_images:    floor_pl,
        photo_url:            primary && (primary['source_url'] || primary['local_url']),
        features:             features_array(home),
        catalog_content_hash: home.content_hash,
        catalog_last_seen_at: Time.current,
        is_deleted:           false,
        deleted_at:           nil
      }
      attrs = guard_blanks(vehicle, attrs) if @protect_blanks && !is_new

      vehicle.assign_attributes(attrs)

      # Required-on-create fields the feed doesn't carry.
      vehicle.year          ||= Date.current.year
      vehicle.serial_number ||= "CAT-#{@source.id}-#{home.source_key}"
      vehicle.location_id     = @location_id if @location_id.present?
      vehicle.catalog_source_id  = @source.id
      vehicle.catalog_source_key = home.source_key.to_s
    end

    # Drop keys whose new value is blank when the existing row already has a
    # populated value (degraded-run safeguard).
    def guard_blanks(vehicle, attrs)
      attrs.reject do |key, value|
        blank_incoming?(value) && vehicle.respond_to?(key) && vehicle.public_send(key).present?
      end
    end

    def blank_incoming?(value)
      value.nil? || (value.respond_to?(:empty?) && value.empty?)
    end

    def inactivate_missing(seen_keys)
      scope = @company.vehicles
                      .where(catalog_source_id: @source.id, is_deleted: [false, nil])
      scope = scope.where.not(catalog_source_key: seen_keys) if seen_keys.any?

      count = 0
      scope.find_each do |vehicle|
        vehicle.update_columns(is_deleted: true, deleted_at: Time.current)
        count += 1
      end
      count
    end

    def features_array(home)
      home.features.flat_map { |section, items| Array(items).map { |i| "#{section}: #{i}" } }
    end

    def manufacturer_name
      @source.config['manufacturer_name'].presence || @source.name
    end
  end
end
