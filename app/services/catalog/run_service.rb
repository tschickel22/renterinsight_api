# frozen_string_literal: true

module Catalog
  # Orchestrates one run of a CatalogSource:
  #   1. discover keys via the adapter
  #   2. fetch + parse each home, accumulating per-field extraction stats
  #   3. compute field_extraction_rates; degraded = any field < threshold
  #   4. if degraded, DO NOT overwrite populated fields with blanks (protect_blanks)
  #   5. upsert into each subscribed dealer's inventory (Vehicle path)
  #   6. mark homes missing from this run inactive (never delete)
  #   7. write the ScrapeRun row + fire a degradation/failure alert
  #
  # Usage: Catalog::RunService.new(source, trigger: 'manual').call
  class RunService
    def initialize(source, trigger: 'manual')
      @source  = source
      @trigger = trigger
    end

    # Parse a source without ingesting or recording a ScrapeRun. Used by the
    # supplement preview/apply rake tasks so we can match catalog homes against
    # existing dealer inventory before any writes happen.
    # Returns [Array<NormalizedHome>, errors].
    def self.parse_only(source)
      adapter = source.adapter
      raise ArgumentError, "No matching adapter for #{source.adapter_type}" if adapter.nil?

      new(source).send(:collect_homes, adapter)
    end

    def call
      run = @source.scrape_runs.create!(status: 'running', trigger: @trigger, started_at: Time.current)
      # Reflect "running" on the source immediately so the list badge updates the
      # moment the job starts, instead of showing the previous status for the
      # whole (multi-minute) crawl.
      @source.update_columns(last_run_status: 'running', last_run_at: run.started_at)
      adapter = @source.adapter

      return fail_run(run, 'No matching adapter for adapter_type') if adapter.nil?

      homes, errors = collect_homes(adapter)
      rates    = ExtractionStats.rates(homes)
      degraded = ExtractionStats.degraded?(rates, @source.extraction_threshold)

      ingest = ingest_into_subscribers(homes, degraded: degraded)

      status = run_status(homes:, errors:, degraded:)
      finalize!(run, homes:, errors:, rates:, degraded:, status:, ingest:)

      DegradationAlerter.call(source: @source, run: run) if degraded || status == 'failed'
      run
    rescue StandardError => e
      Rails.logger.error "[Catalog::RunService] #{@source.id} crashed: #{e.class}: #{e.message}"
      fail_run(run, "#{e.class}: #{e.message}")
    end

    private

    def collect_homes(adapter)
      keys   = Array(adapter.discover)
      homes  = []
      errors = []

      keys.each do |key|
        raw  = adapter.fetch(key)
        home = raw && adapter.parse(raw)
        if home.nil?
          errors << { 'url' => key.to_s, 'message' => 'fetch/parse returned nil' }
        else
          errors << smoke_error(home) unless home.valid_smoke?
          homes << home
        end
        sleep(adapter.crawl_delay) if adapter.crawl_delay.to_i.positive? && !Rails.env.test?
      rescue StandardError => e
        errors << { 'url' => key.to_s, 'message' => "#{e.class}: #{e.message}" }
      end

      [homes, errors]
    end

    def smoke_error(home)
      missing = NormalizedHome::TRACKED_FIELDS.reject { |f| home.field_presence[f] }
      { 'url' => home.source_url.to_s, 'field' => missing.join(','), 'message' => 'failed smoke check' }
    end

    # Ingest into every enabled dealer subscription for this source. With zero
    # subscribers this is a no-op (the run still validates extraction + records
    # health) — exactly what platform-admin onboarding/testing needs.
    def ingest_into_subscribers(homes, degraded:)
      totals = Hash.new(0)
      @source.dealer_catalog_subscriptions.enabled.includes(:company).find_each do |sub|
        next if sub.company.nil?

        target_locations = sub.ingest_location_ids # [nil] for company-wide, else [ids]
        target_locations.each do |loc|
          result = IngestionService.new(
            company:        sub.company,
            source:         @source,
            location_id:    loc,
            protect_blanks: degraded
          ).call(homes)

          totals[:added]       += result.added
          totals[:updated]     += result.updated
          totals[:inactivated] += result.inactivated
        end

        totals[:inactivated] += inactivate_deselected_locations(sub.company, target_locations)
      end
      totals
    end

    # Soft-delete catalog copies at locations the subscription no longer targets
    # (e.g. dealer switched from all -> specific, or removed a location).
    # Supplemented vehicles are never tombstoned — they're dealer-originals.
    def inactivate_deselected_locations(company, target_locations)
      scope = company.vehicles.where(catalog_source_id: @source.id, is_deleted: [false, nil])
      scope = if target_locations == [nil]
                scope.where.not(location_id: nil)            # company-wide: drop pinned copies
              else
                scope.where('location_id IS NULL OR location_id NOT IN (?)', target_locations.compact)
              end
      # Exclude supplement-stamped vehicles. JSONB `->>` returns TEXT, so we
      # compare against the literal 'true' string.
      scope = scope.where("(catalog_last_synced_values->>'__supplemented__') IS DISTINCT FROM 'true'")
      scope.update_all(is_deleted: true, deleted_at: Time.current)
    end

    def run_status(homes:, errors:, degraded:)
      return 'failed' if homes.empty?
      return 'partial' if degraded || errors.any?

      'success'
    end

    def finalize!(run, homes:, errors:, rates:, degraded:, status:, ingest:)
      parsed_ok = homes.count(&:valid_smoke?)
      run.update!(
        status:                 status,
        finished_at:            Time.current,
        homes_discovered:       homes.size + errors.count { |e| e['field'].nil? },
        homes_parsed_ok:        parsed_ok,
        homes_failed:           homes.size - parsed_ok,
        added_count:            ingest[:added].to_i,
        updated_count:          ingest[:updated].to_i,
        inactivated_count:      ingest[:inactivated].to_i,
        removed_count:          0,
        field_extraction_rates: rates,
        degraded:               degraded,
        error_log:              errors
      )
      @source.update!(last_run_at: run.finished_at, last_run_status: status)
      run
    end

    def fail_run(run, message)
      run.update!(
        status:      'failed',
        finished_at: Time.current,
        error_log:   [{ 'message' => message }]
      )
      @source.update!(last_run_at: run.finished_at, last_run_status: 'failed')
      DegradationAlerter.call(source: @source, run: run)
      run
    end
  end
end
