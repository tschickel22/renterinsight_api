# frozen_string_literal: true

module Catalog
  # Applies SupplementMatcher results — for each matched (home, existing
  # vehicle): stamps catalog_source_id + catalog_source_key onto the vehicle,
  # fills only BLANK catalog-managed fields, and snapshots the catalog value
  # into catalog_last_synced_values so re-sync knows what it produced last time.
  #
  # Dealer-owned fields (stock_number, status, price, custom_field_values,
  # owner, location, dealer-edited specs) are NEVER touched. Re-sync via the
  # IngestionService will pick up the same vehicle (matched by source_id+key)
  # and apply the same "only refresh when current == last_synced" rule.
  class SupplementApplier
    Result = Struct.new(:stamped, :fields_filled, :skipped_already_stamped, :unmatched, keyword_init: true)

    def initialize(matches:, source:, dry_run: true)
      @matches = matches
      @source  = source
      @dry_run = dry_run
    end

    def call
      result = Result.new(stamped: 0, fields_filled: 0, skipped_already_stamped: 0, unmatched: 0)

      @matches.each do |m|
        if m.vehicle.nil?
          result.unmatched += 1
          next
        end

        # Already linked to a catalog source — let IngestionService handle re-sync.
        if m.vehicle.catalog_source_id.present?
          result.skipped_already_stamped += 1
          next
        end

        filled = apply_to(m)
        result.stamped       += 1
        result.fields_filled += filled
      end

      result
    end

    private

    # Returns the number of fields newly filled (excluding the catalog_* bookkeeping).
    def apply_to(match)
      vehicle = match.vehicle
      home    = match.home
      catalog_values = Catalog::IngestionService.catalog_attrs_from(home, source: @source)

      filled = 0
      last_synced = {}
      Catalog::IngestionService::MANAGED_FIELDS.each do |field|
        new_value = catalog_values[field]
        current   = vehicle.public_send(field)

        if current.blank? && !blank?(new_value)
          vehicle.public_send("#{field}=", new_value) unless @dry_run
          filled += 1
        end
        last_synced[field.to_s] = serialize(new_value)
      end

      unless @dry_run
        vehicle.catalog_source_id          = @source.id
        vehicle.catalog_source_key         = home.source_key.to_s
        vehicle.catalog_content_hash       = "v#{Catalog::IngestionService::INGESTION_VERSION}:#{home.content_hash}"
        vehicle.catalog_last_seen_at       = Time.current
        vehicle.catalog_last_synced_values = last_synced
        vehicle.source ||= Catalog::IngestionService::VEHICLE_SOURCE
        vehicle.save!
      end

      filled
    end

    def blank?(v)
      v.nil? || (v.respond_to?(:empty?) && v.empty?)
    end

    def serialize(value)
      case value
      when nil      then nil
      when Array    then value.map { |v| v.is_a?(Hash) ? v.deep_stringify_keys : v }
      when Hash     then value.deep_stringify_keys
      else value
      end
    end
  end
end
