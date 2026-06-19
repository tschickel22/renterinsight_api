# frozen_string_literal: true

# Surface B — platform-admin-only management of catalog sources (scrapers +
# feeds) and the hidden health-monitoring view. NOT tenant-scoped: catalog
# sources are platform-level config, so there is no set_company_scope and
# company_id is never permitted in params.
class Api::Admin::CatalogSourcesController < ApplicationController
  before_action :require_platform_admin
  before_action :set_source, only: %i[show update destroy test run_now runs]

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

  # POST /api/v1/admin/catalog_sources
  def create
    source = CatalogSource.new(source_params)
    if source.save
      render json: serialize(source), status: :created
    else
      render json: { errors: source.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # PATCH /api/v1/admin/catalog_sources/:id
  def update
    # Only allow enabling a source after a successful, non-degraded run.
    if enabling?(source_params) && !@source.passed_clean_run? && !force_enable?
      return render json: { error: 'Source must pass a non-degraded test run before it can be enabled' },
                    status: :unprocessable_entity
    end

    if @source.update(source_params)
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

  # POST /api/v1/admin/catalog_sources/:id/test
  # Dry-run: discover + parse the first page, return extraction rates inline.
  # Never ingests. This IS the onboarding flow for a known platform.
  def test
    adapter = @source.adapter
    return render(json: { error: 'no matching adapter — needs build', adapter_type: @source.adapter_type },
                  status: :unprocessable_entity) if adapter.nil?

    limit  = (params[:limit] || 5).to_i.clamp(1, 20)
    homes  = adapter.sample(limit: limit)
    rates  = Catalog::ExtractionStats.rates(homes)

    render json: {
      discovered:             homes.size,
      field_extraction_rates: rates,
      degraded:               Catalog::ExtractionStats.degraded?(rates, @source.extraction_threshold),
      threshold:              @source.extraction_threshold.to_f,
      sample:                 homes.map { |h| sample_home(h) }
    }
  rescue StandardError => e
    Rails.logger.error "[CatalogSources#test] #{e.class}: #{e.message}"
    render json: { error: "Test failed: #{e.message}" }, status: :unprocessable_entity
  end

  # POST /api/v1/admin/catalog_sources/:id/run_now
  def run_now
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
      bedrooms:    home.bedrooms,
      bathrooms:   home.bathrooms,
      squareFeet:  home.square_feet,
      imageCount:  home.images.size,
      validSmoke:  home.valid_smoke?
    }
  end
end
