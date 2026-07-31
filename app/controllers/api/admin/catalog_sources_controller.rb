# frozen_string_literal: true

# Surface B — platform-admin-only management of catalog sources (scrapers +
# feeds) and the hidden health-monitoring view. NOT tenant-scoped: catalog
# sources are platform-level config, so there is no set_company_scope and
# company_id is never permitted in params.
class Api::Admin::CatalogSourcesController < ApplicationController
  # A run still "running" after this long is presumed dead (the in-Puma worker
  # was killed mid-crawl) — it no longer blocks new runs and gets reaped.
  RUN_STALE_AFTER = 30.minutes

  before_action :require_platform_admin
  before_action :set_source, only: %i[show update destroy test run_now runs]

  # Clayton publishes neither a series nor an on-page description for retail
  # home center models, so both would sit at 0% extraction and trip the
  # degradation threshold. Marked untracked at creation (same escape hatch Tru
  # uses) so a healthy Clayton dealer source can reach a clean "success".
  CLAYTON_UNTRACKED_FIELDS = %w[series description].freeze
  # Trove exposes series (it leads the model name) but publishes the description
  # scaffold with empty bodies on every record, so only description is excused.
  TROVE_UNTRACKED_FIELDS   = %w[description].freeze

  # Debounces directory rebuilds across typeahead keystrokes.
  CLAYTON_REFRESH_LOCK = 'clayton_directory_refresh_enqueued'

  # GET /api/v1/admin/catalog_sources
  def index
    sources = CatalogSource.active.order(:name)
    sources = sources.where(adapter_type: params[:adapter_type]) if params[:adapter_type].present?

    render json: {
      items: sources.map { |s| serialize(s) },
      stats: {
        total:           sources.size,
        enabled:         sources.count(&:enabled),
        degraded:        sources.count(&:degraded?),
        failed_last_run: sources.count { |s| s.last_run_status == 'failed' }
      }
    }
  end

  # GET /api/v1/admin/catalog_sources/:id
  def show
    render json: serialize(@source, include_latest_run: true)
  end

  # GET /api/admin/catalog_sources/clayton_home_centers?q=tyler&state=TX
  # Typeahead behind the "Add Clayton Dealer" flow. Serves the cached national
  # directory of Clayton retailers so the admin picks a dealer by name instead
  # of hand-building a base_url.
  def clayton_home_centers
    directory = Catalog::ClaytonHomeCenterDirectory
    # Crawling ~43 state pages takes minutes, so the cache is only ever built by
    # a job. On a cold or stale cache we kick one off and tell the UI to poll.
    ensure_clayton_directory_fresh!

    unless directory.loaded?
      return render json: { items: [], refreshing: true,
                            message: 'Loading Clayton home centers — try again in a minute.' },
                    status: :accepted
    end

    entries = directory.search(params[:q], state: params[:state],
                                          limit: (params[:limit] || 25).to_i.clamp(1, 100))
    taken = CatalogSource.active
                         .where(adapter_type: 'clayton_retail_home_center')
                         .pluck(:base_url, :id).to_h

    render json: {
      items:     entries.map { |e| e.merge('existing_source_id' => taken[e['url']]) },
      fetchedAt: directory.fetched_at,
      refreshing: false
    }
  end

  # POST /api/admin/catalog_sources/refresh_clayton_directory
  def refresh_clayton_directory
    ClaytonDirectoryRefreshJob.perform_later
    render json: { refreshing: true,
                   fetchedAt: Catalog::ClaytonHomeCenterDirectory.fetched_at },
           status: :accepted
  end

  # POST /api/v1/admin/catalog_sources
  #
  # Accepts either a full catalog_source payload or, for the Add Clayton Dealer
  # flow, just { home_center_slug: "mobile-home-masters-inc" } — name, base_url
  # and config are derived from the directory so the admin can't mistype a URL.
  def create
    attrs = params[:home_center_slug].present? ? clayton_source_attrs : source_params
    return if performed?

    attrs = apply_adapter_defaults(attrs, attrs[:adapter_type])
    source = CatalogSource.new(attrs)
    if source.save
      render json: serialize(source), status: :created
    else
      render json: { errors: source.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # PATCH /api/v1/admin/catalog_sources/:id
  def update
    # Only allow enabling after a non-degraded Test or a clean run proved
    # extraction works.
    if enabling?(source_params) && !@source.enableable? && !force_enable?
      return render json: { error: 'Run a Test (or a full run) that passes before enabling this source' },
                    status: :unprocessable_entity
    end

    attrs = apply_adapter_defaults(preserve_derived_config(source_params),
                                   source_params[:adapter_type] || @source.adapter_type)
    if @source.update(attrs)
      render json: serialize(@source)
    else
      render json: { errors: @source.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # DELETE /api/v1/admin/catalog_sources/:id (soft delete)
  def destroy
    @source.soft_delete!
    head :no_content
  end

  # GET /api/admin/catalog_sources/adapter_options
  # Adapter-specific form metadata for the Add Source dialog. Frontend calls
  # this when the admin picks an adapter type that needs extra config (e.g.
  # Clayton Epic's region selector) so the option list stays authoritative
  # on the backend.
  def adapter_options
    render json: {
      clayton_epic_region: {
        base_url_template: 'https://claytonepicexperience.com/homes/?region={region_id}',
        regions: Catalog::Adapters::ClaytonEpicRegionAdapter::REGIONS.map do |id, label|
          { id: id, label: label }
        end,
        # Epic Experience is a narrow promotional line — 7 distinct floor plans
        # published as 37 SKUs (the leading 2 digits are a plant code). Where a
        # retailer carries it, those models ALREADY appear in their home center
        # catalog, so running both sources double-ingests the same model_id.
        advisory: 'Prefer a Clayton dealer source. Retailers who carry the Epic line ' \
                  'already list those models in their own catalog — enabling both ' \
                  'ingests them twice.'
      },
      clayton_retail_home_center: {
        # base_url is derived from the picked home center; admins never type it.
        picker_endpoint:  '/api/admin/catalog_sources/clayton_home_centers',
        refresh_endpoint: '/api/admin/catalog_sources/refresh_clayton_directory',
        untracked_fields: CLAYTON_UNTRACKED_FIELDS,
        options: [
          { key: 'include_starting_price', label: 'Pull starting price', type: 'boolean', default: true,
            help: "Adds this market's starting price to each model. Stored as a suggestion — " \
                  'it never overwrites the dealer\'s own price. Costs ~7 extra requests per run.' }
        ]
      },
      trove_catalog: {
        base_url_template: 'https://trove.{manufacturer}.com',
        untracked_fields: TROVE_UNTRACKED_FIELDS,
        snapshots: Catalog::TroveSnapshot.keys.map do |key|
          snap = Catalog::TroveSnapshot.read(key) || {}
          { key: key, label: snap['supplier_name'].presence || key,
            captured_at: snap['captured_at'], home_count: Array(snap['homes']).size }
        end,
        options: [
          { key: 'snapshot_key', label: 'Run from snapshot', type: 'select', default: nil,
            help: 'Trove answers 429 to any non-browser client, so a live crawl needs the host ' \
                  'to allowlist us first. A snapshot runs the same parsing path against a ' \
                  'captured catalog. Clear this to go live once allowlisted.' }
        ],
        # Per-dealer Trove storefronts republish the manufacturer catalog with
        # their own markup, and are Disallow: / in robots.txt. Point sources at
        # manufacturer hosts; retail price stays dealer-owned in DealerTide.
        advisory: 'Use the manufacturer host (trove.<maker>.com). Dealer storefronts ' \
                  '(*.buildtrove.com) disallow crawling and add nothing but their own markup.'
      }
    }
  end

  # POST /api/admin/catalog_sources/:id/test
  # Dry-run: discover + parse the first page, return extraction rates inline.
  # Never ingests. This IS the onboarding flow for a known platform.
  def test
    adapter = @source.adapter
    return render(json: { error: 'no matching adapter — needs build', adapter_type: @source.adapter_type },
                  status: :unprocessable_entity) if adapter.nil?

    limit    = (params[:limit] || 5).to_i.clamp(1, 20)
    # Test is a SAMPLE capped at 20, so report the full catalog size alongside it
    # or "Discovered: 10" reads as "this source only has 10 homes". Adapters
    # memoize their listing fetch, so this adds no extra request.
    available = begin
      Array(adapter.discover).size
    rescue StandardError
      nil
    end
    homes    = adapter.sample(limit: limit)
    rates    = Catalog::ExtractionStats.rates(homes)
    degraded = Catalog::ExtractionStats.degraded?(rates, @source.extraction_threshold, untracked: @source.untracked_fields)
    passed   = homes.any? && !degraded

    # Record a passing Test so it satisfies the enable gate (no full run needed).
    @source.record_test_pass! if passed

    # Discovery guard: zero discovered homes is a failed test, not a pass — the
    # base_url / selectors don't match. Surface it explicitly so the FE (and the
    # enable gate) treat it as a problem even though no error was raised.
    warnings = []
    warnings << 'Discovery returned 0 homes — check base_url and adapter selectors.' if homes.empty?

    payload = {
      discovered:             homes.size,
      available:              available,
      sampled:                homes.size < available.to_i,
      passed:                 passed,
      warnings:               warnings,
      field_extraction_rates: rates,
      degraded:               degraded,
      threshold:              @source.extraction_threshold.to_f,
      sample:                 homes.map { |h| sample_home(h) }
    }
    # On zero discovery, attach what the SERVER actually saw (status, link
    # counts, block-page detection) so the failure is diagnosable from the env
    # it runs in — local vs Render can differ (WAF, geo, egress). Also log it,
    # since the response isn't always surfaced in the UI.
    if homes.empty?
      diag = (adapter.diagnostics rescue { error: 'diagnostics failed' })
      payload[:diagnostics] = diag
      Rails.logger.warn "[CatalogSources#test] zero-discovery source=#{@source.id} " \
                        "adapter=#{@source.adapter_type} base_url=#{@source.base_url} diagnostics=#{diag.inspect}"
    end

    render json: payload
  rescue StandardError => e
    Rails.logger.error "[CatalogSources#test] #{e.class}: #{e.message}"
    render json: { error: "Test failed: #{e.message}" }, status: :unprocessable_entity
  end

  # POST /api/admin/catalog_sources/:id/run_now
  def run_now
    reap_stale_runs!

    # Don't stack crawls — one run per source at a time. A run still marked
    # "running" after RUN_STALE_AFTER is treated as dead (the in-Puma worker can
    # be killed by a deploy/restart mid-crawl) and does not block a new run.
    if @source.scrape_runs.where(status: 'running').exists?
      return render json: { message: 'A run is already in progress for this source' }, status: :conflict
    end

    CatalogSourceRunJob.perform_later(@source.id, trigger: 'manual')
    render json: { message: 'Run queued' }, status: :accepted
  end

  # GET /api/v1/admin/catalog_sources/:id/runs
  def runs
    runs = @source.scrape_runs.recent.limit((params[:limit] || 50).to_i.clamp(1, 200))
    render json: { items: runs.map { |r| serialize_run(r) } }
  end

  private

  def require_platform_admin
    return if current_user&.role == 'platform_admin' || current_user&.super_admin?

    render json: { error: 'Unauthorized - Platform admin access required' }, status: :forbidden
  end

  # Mark long-stuck "running" runs as failed so they don't block new runs or show
  # as perpetually running. (A crawl runs in-Puma and can be killed mid-flight by
  # a deploy/restart, leaving the row never finalized.)
  def reap_stale_runs!
    stale = @source.scrape_runs.where(status: 'running').where(started_at: ..RUN_STALE_AFTER.ago).to_a
    return if stale.empty?

    stale.each do |run|
      run.update!(status: 'failed', finished_at: Time.current,
                  error_log: [{ 'message' => 'Run did not finish (worker stopped) — marked stale' }])
    end
    @source.update_columns(last_run_status: 'failed') if @source.last_run_status == 'running'
  end

  def set_source
    @source = CatalogSource.active.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Catalog source not found' }, status: :not_found
  end

  # NOTE: company_id intentionally NOT permitted — catalog sources are platform-level.
  def source_params
    params.require(:catalog_source).permit(
      :name, :adapter_type, :base_url, :manufacturer_id, :enabled,
      :schedule, :extraction_threshold, config: {}
    )
  end

  # Enqueue a rebuild when the cache is empty or past its TTL. Guarded so rapid
  # typeahead keystrokes don't pile up duplicate crawls.
  def ensure_clayton_directory_fresh!
    return unless Catalog::ClaytonHomeCenterDirectory.stale?
    return if Rails.cache.exist?(CLAYTON_REFRESH_LOCK)

    Rails.cache.write(CLAYTON_REFRESH_LOCK, true, expires_in: 10.minutes)
    ClaytonDirectoryRefreshJob.perform_later
  end

  # Build a Clayton dealer source from a directory slug. Renders an error and
  # returns nil when the slug is unknown or already registered — callers must
  # check `performed?`.
  def clayton_source_attrs
    slug  = params[:home_center_slug].to_s.strip
    entry = Catalog::ClaytonHomeCenterDirectory.find_by_slug(slug)
    if entry.nil?
      render json: { error: "Unknown Clayton home center: #{slug}" }, status: :unprocessable_entity
      return nil
    end

    existing = CatalogSource.active.find_by(adapter_type: 'clayton_retail_home_center',
                                            base_url: entry['url'])
    if existing
      render json: { error: "#{entry['name']} is already registered", sourceId: existing.id },
             status: :conflict
      return nil
    end

    overrides = params.fetch(:catalog_source, {}).permit(:schedule, :extraction_threshold).to_h
    {
      name:         clayton_source_name(entry),
      adapter_type: 'clayton_retail_home_center',
      base_url:     entry['url'],
      schedule:     'weekly',
      config: {
        'untracked_fields'       => CLAYTON_UNTRACKED_FIELDS,
        'include_starting_price' => include_starting_price?,
        'home_center'            => entry.slice('slug', 'dealer_id', 'dealer_number', 'brand',
                                                'city', 'state', 'postal_code')
      }
    }.merge(overrides.symbolize_keys)
  end

  # "Clayton — Mobile Home Masters Inc (Tyler, TX)"
  def clayton_source_name(entry)
    where = [entry['city'], entry['state']].compact_blank.join(', ')
    base  = "Clayton — #{entry['name']}"
    where.present? ? "#{base} (#{where})" : base
  end

  # Defaults ON: starting price costs ~7 extra requests per run and dealers who
  # don't want it can turn it off rather than discover it missing.
  def include_starting_price?
    raw = params[:include_starting_price]
    raw.nil? ? true : ActiveModel::Type::Boolean.new.cast(raw) != false
  end

  # Some config keys are derived by the server at creation, not typed by the
  # admin: home_center identity and the untracked_fields that let a Clayton
  # source reach a clean run. A client that PATCHes config without echoing them
  # back would silently drop them, which flips the source to permanently
  # degraded. Re-merge anything the payload doesn't explicitly set.
  # snapshot_key is here so a form that round-trips config without it (or opens
  # before adapter options load) cannot silently un-bind a snapshot and send the
  # source back to live crawling. Clearing it — the go-live step — is still
  # possible: send snapshot_key explicitly as null, which counts as "set".
  DERIVED_CONFIG_KEYS = %w[home_center untracked_fields test_passed_at snapshot_key].freeze

  # Config an admin should not have to know to type. Trove publishes the
  # description scaffold with empty bodies on EVERY record, so without this a
  # UI-created source scores 0% on description, lands "partial" on an otherwise
  # perfect 93/93 run, and can never be enabled.
  ADAPTER_CONFIG_DEFAULTS = {
    'trove_catalog' => { 'untracked_fields' => TROVE_UNTRACKED_FIELDS }
  }.freeze

  def apply_adapter_defaults(attrs, adapter_type)
    defaults = ADAPTER_CONFIG_DEFAULTS[adapter_type.to_s]
    return attrs if defaults.blank?

    config = config_hash(attrs[:config])
    defaults.each { |key, value| config[key] = value unless config[key].present? }
    attrs.merge(config: config)
  end

  # attrs may already have been through preserve_derived_config, whose
  # Parameters#merge re-wraps the nested config as UNPERMITTED Parameters —
  # so a plain #to_h on it raises. These values are ours, not user input we
  # still need to filter, hence to_unsafe_h.
  def config_hash(raw)
    case raw
    when ActionController::Parameters then raw.to_unsafe_h.stringify_keys
    when Hash then raw.stringify_keys
    else {}
    end
  end

  def preserve_derived_config(attrs)
    incoming = attrs[:config]
    return attrs if incoming.nil?

    existing = @source.config.is_a?(Hash) ? @source.config : {}
    merged   = incoming.to_h.stringify_keys
    DERIVED_CONFIG_KEYS.each do |key|
      merged[key] = existing[key] if !merged.key?(key) && existing.key?(key)
    end

    attrs.merge(config: merged)
  end

  def enabling?(attrs)
    ActiveModel::Type::Boolean.new.cast(attrs[:enabled]) == true && !@source.enabled
  end

  def force_enable?
    ActiveModel::Type::Boolean.new.cast(params[:force]) == true
  end

  def serialize(source, include_latest_run: false)
    latest = source.latest_run
    data = {
      id:                  source.id,
      name:                source.name,
      adapterType:         source.adapter_type,
      baseUrl:             source.base_url,
      manufacturerId:      source.manufacturer_id,
      config:              source.config || {},
      enabled:             source.enabled,
      schedule:            source.schedule,
      extractionThreshold: source.extraction_threshold.to_f,
      lastRunAt:           source.last_run_at,
      lastRunStatus:       source.last_run_status,
      degraded:            source.degraded?,
      worstFieldRate:      source.worst_field_rate,
      # Latest run's parsed count for the list column (nil when never run).
      homesParsedOk:       latest&.homes_parsed_ok,
      homesDiscovered:     latest&.homes_discovered,
      selectableForDealers: source.selectable_for_dealers?,
      createdAt:           source.created_at,
      updatedAt:           source.updated_at
    }
    data[:latestRun] = latest && serialize_run(latest) if include_latest_run
    data
  end

  def serialize_run(run)
    {
      id:                    run.id,
      status:                run.status,
      trigger:               run.trigger,
      startedAt:             run.started_at,
      finishedAt:            run.finished_at,
      durationSeconds:       run.duration_seconds,
      homesDiscovered:       run.homes_discovered,
      homesParsedOk:         run.homes_parsed_ok,
      homesFailed:           run.homes_failed,
      addedCount:            run.added_count,
      updatedCount:          run.updated_count,
      removedCount:          run.removed_count,
      inactivatedCount:      run.inactivated_count,
      fieldExtractionRates:  run.field_extraction_rates || {},
      worstFieldRate:        run.worst_field_rate,
      degraded:              run.degraded,
      errorLog:              run.error_log || [],
      createdAt:             run.created_at
    }
  end

  def sample_home(home)
    {
      sourceKey:   home.source_key,
      sourceUrl:   home.source_url,
      modelName:   home.model_name,
      modelId:     home.model_id,
      series:      home.series,
      # Keys MUST match the FE sample table (beds/baths/sqft), not the model
      # attribute names — otherwise the columns render blank ("—").
      beds:        home.bedrooms,
      baths:       home.bathrooms,
      sqft:        home.square_feet,
      dimensions:  home.dimensions,
      imageCount:  home.images.size,
      validSmoke:  home.valid_smoke?,
      # Clayton retail sources only — lets the admin confirm the starting-price
      # toggle actually produced prices before enabling. nil for other adapters.
      startingPrice: home.raw.is_a?(Hash) ? home.raw['starting_price'] : nil,
      inStock:       home.raw.is_a?(Hash) ? home.raw['in_stock'] : nil
    }
  end
end
