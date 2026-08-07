# frozen_string_literal: true

# Surface B — platform-admin-only management of catalog sources (scrapers +
# feeds) and the hidden health-monitoring view. NOT tenant-scoped: catalog
# sources are platform-level config, so there is no set_company_scope and
# company_id is never permitted in params.
class Api::Admin::CatalogSourcesController < ApplicationController
  # Staleness lives on ScrapeRun (ScrapeRun::STALE_AFTER) so the nightly sweep
  # and the subscription path reap too, not only this controller.

  before_action :require_platform_admin
  before_action :set_source, only: %i[show update destroy test run_now runs seed_inventory]

  # Clayton publishes neither a series nor an on-page description for retail
  # home center models, so both would sit at 0% extraction and trip the
  # degradation threshold. Marked untracked at creation (same escape hatch Tru
  # uses) so a healthy Clayton dealer source can reach a clean "success".
  CLAYTON_UNTRACKED_FIELDS = %w[series description].freeze
  # Trove exposes series (it leads the model name) but publishes the description
  # scaffold with empty bodies on every record, so only description is excused.
  TROVE_UNTRACKED_FIELDS   = %w[description].freeze
  # Cavco publishes series and full specs, but no prose description on floorplans.
  CAVCO_UNTRACKED_FIELDS   = %w[description].freeze

  # Timber Creek publishes series, a prose description and full specs on every
  # floor plan, so nothing needs excusing.
  TIMBER_CREEK_UNTRACKED_FIELDS = [].freeze

  # Adventure Homes publishes series and full specs on all 130 plans, but no
  # descriptive copy anywhere on the site — a full crawl found zero.
  ADVENTURE_UNTRACKED_FIELDS = %w[description].freeze

  # Debounces directory rebuilds across typeahead keystrokes.
  CLAYTON_REFRESH_LOCK      = 'clayton_directory_refresh_enqueued'
  TIMBER_CREEK_REFRESH_LOCK = 'timber_creek_directory_refresh_enqueued'

  # GET /api/v1/admin/catalog_sources
  def index
    # Un-stick sources whose run was killed by a deploy, so the list stops
    # reporting a crawl that no worker is running. Cheap: a no-op unless a row
    # is genuinely past STALE_AFTER.
    ScrapeRun.reap_stale!

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
    attrs = if params[:home_center_slug].present?
              clayton_source_attrs
            elsif params[:cavco_retailer_id].present?
              cavco_source_attrs
            elsif params[:timber_creek_dealer_id].present?
              timber_creek_source_attrs
            else
              source_params
            end
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
      manufacturedhomes_platform: {
        # The manufacturer-wide shape: base_url is a floor plan grid, typed by
        # hand. For ONE retailer's inventory use timber_creek_dealer instead.
        base_url_template: 'https://www.{manufacturer}.com/manufactured-home-floor-plans/',
        options: [],
        advisory: 'This ingests a manufacturer\'s ENTIRE catalog. To give a dealer only ' \
                  'their own homes, add a Timber Creek dealer source instead.'
      },
      timber_creek_dealer: {
        # base_url is derived from the picked dealer; admins never type it. Same
        # adapter as manufacturedhomes_platform — the platform scopes a
        # retailer's page to their own inventory, so no filtering is needed here.
        picker_endpoint:  '/api/admin/catalog_sources/timber_creek_dealers',
        refresh_endpoint: '/api/admin/catalog_sources/refresh_timber_creek_directory',
        untracked_fields: TIMBER_CREEK_UNTRACKED_FIELDS,
        options: [],
        advisory: 'Returns only this retailer\'s homes — Timber Creek scopes their dealer ' \
                  'page for us, so there is no radius or filtering to configure.'
      },
      cavco_retailer: {
        picker_endpoint:  '/api/admin/catalog_sources/cavco_retailers',
        refresh_endpoint: '/api/admin/catalog_sources/refresh_cavco_directory',
        untracked_fields: CAVCO_UNTRACKED_FIELDS,
        options: [],
        # Cavco already resolves which models a retailer may sell, and that
        # assignment spans the whole family of brands, so there is nothing to
        # filter. The brand sites link back to this same directory.
        advisory: 'Cavco assigns each dealer their own model list, already spanning every ' \
                  'brand they carry (Cavco, Palm Harbor, Fleetwood, Solitaire and the rest). ' \
                  'No separate source per brand is needed.'
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
      },
      adventure_homes: {
        base_url_template: 'https://adventurehomes.net',
        untracked_fields: ADVENTURE_UNTRACKED_FIELDS,
        options: [],
        advisory: 'Ingests all 130 published floor plans. Features come from the ' \
                  'series Standard Features PDF, so they describe the series and not ' \
                  'the individual home. Adventure publishes no prices (their retailer ' \
                  'quotes) and no descriptions.'
      }
    }
  end

  # GET /api/admin/catalog_sources/cavco_retailers?q=amarillo&state=TX
  # Typeahead behind "Add Cavco Dealer". Cavco indexes retailers as documents in
  # the same engine as the homes, so unlike Clayton's 43-page crawl a refresh is
  # a handful of queries — quick enough to build inline on a cold cache.
  def cavco_retailers
    directory = Catalog::CavcoRetailerDirectory
    directory.refresh! if !directory.loaded? || directory.stale?

    entries = directory.search(params[:q], state: params[:state],
                                           limit: (params[:limit] || 25).to_i.clamp(1, 100))
    taken = CatalogSource.active
                         .where(adapter_type: 'cavco_retailer')
                         .filter_map { |s| [s.config.is_a?(Hash) ? s.config['retailer_id'] : nil, s.id] }
                         .to_h

    render json: {
      items:      entries.map { |e| e.merge('existing_source_id' => taken[e['id']]) },
      fetchedAt:  directory.fetched_at,
      refreshing: false
    }
  rescue StandardError => e
    Rails.logger.error "[CatalogSources] cavco_retailers failed: #{e.class}: #{e.message}"
    render json: { items: [], error: 'Could not reach the Cavco retailer directory' },
           status: :service_unavailable
  end

  # POST /api/admin/catalog_sources/refresh_cavco_directory
  def refresh_cavco_directory
    entries = Catalog::CavcoRetailerDirectory.refresh!
    render json: { refreshing: false, count: entries.size,
                   fetchedAt: Catalog::CavcoRetailerDirectory.fetched_at }
  rescue StandardError => e
    render json: { error: "Refresh failed: #{e.message}" }, status: :service_unavailable
  end

  # GET /api/admin/catalog_sources/timber_creek_dealers?q=atchafalaya&state=LA
  # Typeahead behind "Add Timber Creek Dealer". Walking ~14 state pages takes
  # ~45s, which is too long to hold a web request open, so this follows the
  # Clayton pattern: a job builds the cache and the UI polls.
  def timber_creek_dealers
    directory = Catalog::TimberCreekDealerDirectory
    ensure_timber_creek_directory_fresh!

    unless directory.loaded?
      return render json: { items: [], refreshing: true,
                            message: 'Loading Timber Creek retailers — try again in a minute.' },
                    status: :accepted
    end

    entries = directory.search(params[:q], state: params[:state],
                                           limit: (params[:limit] || 25).to_i.clamp(1, 100))
    # Keyed on base_url, which for this adapter is the dealer's own page and so
    # is unique per dealership — the slug is not (five separate Marty Wright
    # locations share one).
    taken = CatalogSource.active
                         .where(adapter_type: %w[timber_creek_dealer manufacturedhomes_platform])
                         .pluck(:base_url, :id).to_h

    render json: {
      items:      entries.map { |e| e.merge('existing_source_id' => taken[e['url']]) },
      fetchedAt:  directory.fetched_at,
      refreshing: false
    }
  end

  # POST /api/admin/catalog_sources/refresh_timber_creek_directory
  def refresh_timber_creek_directory
    TimberCreekDirectoryRefreshJob.perform_later
    render json: { refreshing: true,
                   fetchedAt: Catalog::TimberCreekDealerDirectory.fetched_at },
           status: :accepted
  end

  # POST /api/admin/catalog_sources/:id/seed_inventory
  # One-time onboarding import of a Cavco dealer's ACTUAL lot. Deliberately a
  # button rather than an automatic side effect of subscribing: it writes real
  # inventory rows (including sold and pending homes) into a dealer's account,
  # which should be a decision someone makes, not a surprise.
  #
  # Safe to press twice — the seeder is write-once on Cavco's inventory UUID, so
  # a re-run adds nothing and never overwrites a status the dealer has changed.
  def seed_inventory
    adapter = @source.adapter
    unless adapter.respond_to?(:inventory_documents)
      return render json: { error: "#{@source.adapter_type} does not publish dealer inventory" },
                    status: :unprocessable_entity
    end

    subs = @source.dealer_catalog_subscriptions.enabled.includes(:company)
    subs = subs.where(company_id: params[:company_id]) if params[:company_id].present?
    if subs.empty?
      return render json: { error: 'No dealer is subscribed to this source yet' },
                    status: :unprocessable_entity
    end

    documents = adapter.inventory_documents
    if documents.empty?
      return render json: { error: 'The manufacturer reports no inventory for this dealership' },
                    status: :unprocessable_entity
    end

    results = subs.filter_map do |sub|
      next if sub.company.nil?

      totals = Hash.new(0)
      sub.ingest_location_ids.each do |location_id|
        r = Catalog::CavcoInventorySeeder.new(company: sub.company, source: @source,
                                              location_id: location_id).call(documents)
        totals[:created]          += r.created
        totals[:skipped_existing] += r.skipped_existing
        totals[:skipped]          += r.skipped_unmappable
      end

      { companyId: sub.company_id, companyName: sub.company.name,
        created: totals[:created], alreadyPresent: totals[:skipped_existing],
        skipped: totals[:skipped] }
    end

    render json: { available: documents.size, results: results }
  rescue StandardError => e
    Rails.logger.error "[CatalogSources] seed_inventory failed for #{@source.id}: #{e.class}: #{e.message}"
    render json: { error: "Seeding failed: #{e.message}" }, status: :unprocessable_entity
  end

  # POST /api/admin/catalog_sources/upload_snapshot
  # Loads a catalog captured by db/catalog_snapshots/capture_trove.js. Until
  # Trove allowlists us, refreshing inventory means re-capturing, and that
  # should not require a production shell — this is the whole self-service
  # path for "Legacy added models, pull them in".
  #
  # Re-uploading the same key overwrites it. That is intended: the next run
  # diffs each home's catalog_content_hash, so only genuinely changed models
  # are updated and dealer edits are still protected.
  def upload_snapshot
    payload = params[:snapshot]
    payload = payload.to_unsafe_h if payload.is_a?(ActionController::Parameters)

    unless payload.is_a?(Hash)
      return render json: { error: 'Expected a snapshot object' }, status: :unprocessable_entity
    end

    payload = payload.deep_stringify_keys
    key     = params[:key].presence || derive_snapshot_key(payload)

    if key.blank?
      return render json: { error: 'Could not determine a snapshot key — pass `key`' },
                    status: :unprocessable_entity
    end

    homes = Array(payload['homes'])
    if homes.empty?
      return render json: { error: 'Snapshot contains no homes' }, status: :unprocessable_entity
    end

    previous = Catalog::TroveSnapshot.read(key)
    Catalog::TroveSnapshot.write(key, payload)

    render json: {
      key: key,
      supplier_name: payload['supplier_name'],
      captured_at: payload['captured_at'],
      home_count: homes.size,
      image_count: homes.sum { |h| Array(h['images']).size },
      homes_without_images: homes.count { |h| Array(h['images']).empty? },
      replaced: previous.present?,
      # So the admin can see at a glance whether the re-capture actually moved.
      previous_home_count: previous ? Array(previous['homes']).size : nil,
      previous_captured_at: previous&.dig('captured_at')
    }
  rescue ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_entity
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
  # Reaping lives on ScrapeRun so every reader benefits, not just this button.
  def reap_stale_runs!
    ScrapeRun.reap_stale!(@source.scrape_runs)
    @source.reload
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

  def ensure_timber_creek_directory_fresh!
    return unless Catalog::TimberCreekDealerDirectory.stale?
    return if Rails.cache.exist?(TIMBER_CREEK_REFRESH_LOCK)

    Rails.cache.write(TIMBER_CREEK_REFRESH_LOCK, true, expires_in: 10.minutes)
    TimberCreekDirectoryRefreshJob.perform_later
  end

  # Build a Timber Creek dealer source from a directory dealer id. Renders an
  # error and returns nil when the id is unknown or already registered — callers
  # must check `performed?`.
  #
  # base_url is the dealer's own page, which the platform already scopes to that
  # retailer's inventory, so the adapter needs no dealer filtering config beyond
  # what it infers from the URL.
  def timber_creek_source_attrs
    id    = params[:timber_creek_dealer_id].to_s.strip
    entry = Catalog::TimberCreekDealerDirectory.find_by_dealer_id(id)
    if entry.nil?
      render json: { error: "Unknown Timber Creek dealer: #{id}" }, status: :unprocessable_entity
      return nil
    end

    existing = CatalogSource.active.find_by(
      adapter_type: %w[timber_creek_dealer manufacturedhomes_platform],
      base_url: entry['url']
    )
    if existing
      render json: { error: "#{entry['name']} is already registered", sourceId: existing.id },
             status: :conflict
      return nil
    end

    overrides = params.fetch(:catalog_source, {}).permit(:schedule, :extraction_threshold).to_h
    {
      name:         timber_creek_source_name(entry),
      adapter_type: 'timber_creek_dealer',
      base_url:     entry['url'],
      schedule:     'weekly',
      config: {
        'untracked_fields' => TIMBER_CREEK_UNTRACKED_FIELDS,
        'dealer_id'        => entry['dealer_id'].to_s,
        'dealer'           => entry.slice('dealer_id', 'slug', 'name', 'city', 'state',
                                          'postal_code', 'phone', 'website_url')
      }
    }.merge(overrides.symbolize_keys)
  end

  # "Timber Creek — Atchafalaya Homes (Carencro, LA)"
  def timber_creek_source_name(entry)
    where = [entry['city'], entry['state']].compact_blank.join(', ')
    base  = "Timber Creek — #{entry['name']}"
    where.present? ? "#{base} (#{where})" : base
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
  def cavco_source_attrs
    id    = params[:cavco_retailer_id].to_s.strip
    entry = Catalog::CavcoRetailerDirectory.find_by_id(id)
    if entry.nil?
      render json: { error: "Unknown Cavco retailer: #{id}" }, status: :unprocessable_entity
      return nil
    end

    existing = CatalogSource.active.where(adapter_type: 'cavco_retailer').find do |s|
      s.config.is_a?(Hash) && s.config['retailer_id'] == id
    end
    if existing
      render json: { error: "#{entry['name']} is already registered", sourceId: existing.id },
             status: :conflict
      return nil
    end

    overrides = params.fetch(:catalog_source, {}).permit(:schedule, :extraction_threshold).to_h
    {
      name:         cavco_source_name(entry),
      adapter_type: 'cavco_retailer',
      base_url:     entry['url'],
      schedule:     'weekly',
      config: {
        'retailer_id'      => id,
        'untracked_fields' => CAVCO_UNTRACKED_FIELDS,
        'retailer'         => entry.slice('id', 'name', 'location_id', 'city', 'state',
                                          'postal_code', 'location_type')
      }
    }.merge(overrides.symbolize_keys)
  end

  # "Cavco - Amarillo Home Center, LLC (Amarillo, TX)"
  def cavco_source_name(entry)
    place = [entry['city'], entry['state']].compact.join(', ')
    place.present? ? "Cavco - #{entry['name']} (#{place})" : "Cavco - #{entry['name']}"
  end

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
  # "Legacy Housing" -> "legacy_housing", matching what catalog:snapshot:load
  # produces. Deriving from the host instead would yield "legacyhousing", which
  # would NOT match an already-bound source — the upload would quietly create a
  # second snapshot and refresh nothing. The host is only a fallback.
  #
  # The UI passes `key` explicitly when re-capturing for an existing source, so
  # this only runs for a first upload.
  def derive_snapshot_key(payload)
    from_name = payload['supplier_name'].to_s.parameterize(separator: '_')
    return from_name if from_name.present?

    host = begin
      URI.parse(payload['base_url'].to_s).host
    rescue URI::InvalidURIError
      nil
    end
    host.to_s.split('.').reject { |p| %w[www trove com net org].include?(p) }.join('_').presence
  end

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
