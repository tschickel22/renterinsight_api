# frozen_string_literal: true

# TrueView lab: one model photo, one set of finishes, every image model side
# by side with its time and cost. Platform admins only; it spends real money
# on the providers' accounts. Platform data, so no company scope.
class Api::Admin::TrueviewLabController < ApplicationController
  before_action :require_platform_admin!

  RENDER_ROOMS = %w[kitchen bath living bedroom dining laundry exterior].freeze
  MAX_FINISHES = 8

  # GET /api/admin/trueview_lab
  # Models with photos, the image models on offer, and finish suggestions.
  def index
    variants = CatalogPlanVariant.where("jsonb_array_length(COALESCE(media->'photos', '[]'::jsonb)) > 0")
                                 .order(:manufacturer_id, :model_number).limit(400)
    render json: {
      models: Truebuild::Trueview::MODELS.map { |key, s| { key: key, label: s[:label], provider: s[:provider], configured: Truebuild::Trueview.configured?(key) } },
      variants: variants.map do |v|
        { id: v.id, name: v.media['name'].presence || v.model_number, model_number: v.model_number, manufacturer_id: v.manufacturer_id,
          photos: Array(v.media['photos']).select { |p| p['url'].present? }.map { |p| p.slice('url', 'room') } }
      end
    }
  end

  # GET /api/admin/trueview_lab/finishes?variant_id=
  # The manufacturer's named colors, as suggestions for the finish rows.
  def finishes
    variant = CatalogPlanVariant.find_by(id: params[:variant_id])
    return render json: { sets: [] } unless variant

    sets = CatalogOption.where(manufacturer_id: variant.manufacturer_id, kind: 'color', status: 'active')
                        .pluck(:name, Arel.sql("metadata->>'color_set'"))
                        .group_by { |_, set| set.presence || 'Colors' }
                        .map { |set, rows| { name: set, values: rows.map(&:first).uniq.sort.first(60) } }
                        .sort_by { |s| s[:name] }
    render json: { sets: sets }
  end

  # GET /api/admin/trueview_lab/runs
  def runs
    rows = TruebuildRender.where.not(lab_run: nil).order(created_at: :desc).limit(400)
    render json: { runs: rows.group_by(&:lab_run).first(20).map { |run, rs| run_json(run, rs) } }
  end

  # GET /api/admin/trueview_lab/runs/:id
  def show_run
    rows = TruebuildRender.where(lab_run: params[:id]).order(:id).to_a
    return render json: { error: 'Not found' }, status: :not_found if rows.empty?

    render json: run_json(params[:id], rows)
  end

  # POST /api/admin/trueview_lab/runs
  # { variant_id, source_url, room, finishes: [{surface, value}], models: [key], fresh }
  def create_run
    variant = CatalogPlanVariant.find_by(id: params[:variant_id])
    return render json: { error: 'Choose a model' }, status: :unprocessable_entity unless variant

    # Only the model's own photos: the job fetches this URL from the server.
    photo = Array(variant.media['photos']).find { |p| p['url'] == params[:source_url].to_s }
    return render json: { error: 'Choose one of this model\'s photos' }, status: :unprocessable_entity unless photo

    selection = TruebuildRender.normalize(Array(params[:finishes]).map { |f| f.permit(:surface, :value).to_h }).first(MAX_FINISHES)
    return render json: { error: 'Add at least one finish' }, status: :unprocessable_entity if selection.empty?

    keys = Array(params[:models]).map(&:to_s) & Truebuild::Trueview::MODELS.keys
    return render json: { error: 'Choose at least one image model' }, status: :unprocessable_entity if keys.empty?

    room = RENDER_ROOMS.include?(params[:room].to_s) ? params[:room].to_s : photo['room']
    run = SecureRandom.uuid
    selection_key = TruebuildRender.key_for(selection)
    prompt = Truebuild::Trueview.prompt(room: room, selection: selection)
    rows = keys.map do |key|
      spec = Truebuild::Trueview::MODELS[key]
      cached = !ActiveModel::Type::Boolean.new.cast(params[:fresh]) &&
               TruebuildRender.done.where(source_url: photo['url'], selection_key: selection_key, model_key: key).order(:id).last
      attrs = { catalog_plan_variant_id: variant.id, room: room, source_url: photo['url'], selection: selection,
                selection_key: selection_key, model_key: key, provider: spec[:provider], model: spec[:model], prompt: prompt, lab_run: run }
      if cached
        # Served from the cache: what a buyer repeating this combination costs.
        TruebuildRender.create!(attrs.merge(status: 'done', image_url: cached.image_url, latency_ms: 0, cost_usd: 0,
                                            usage: { 'cached_from' => cached.id }, model: cached.model))
      elsif !Truebuild::Trueview.configured?(key)
        TruebuildRender.create!(attrs.merge(status: 'failed', error: "#{spec[:provider] == 'gemini' ? 'GEMINI' : 'OPENAI'}_API_KEY is not set"))
      else
        TruebuildRender.create!(attrs).tap { |r| TruebuildRenderJob.perform_later(r.id) }
      end
    end
    render json: run_json(run, rows), status: :created
  end

  private

  def run_json(run, rows)
    first = rows.first
    { id: run, created_at: first.created_at, variant_id: first.catalog_plan_variant_id, room: first.room,
      source_url: first.source_url, finishes: first.selection, prompt: first.prompt,
      total_cost_usd: rows.sum { |r| r.cost_usd.to_f }.round(4),
      renders: rows.map do |r|
        spec = Truebuild::Trueview::MODELS[r.model_key] || {}
        { id: r.id, model_key: r.model_key, label: spec[:label] || r.model_key, provider: r.provider, model: r.model,
          status: r.status, image_url: r.image_url, cost_usd: r.cost_usd&.to_f, latency_ms: r.latency_ms,
          usage: r.usage, error: r.error, cached: r.usage.is_a?(Hash) && r.usage.key?('cached_from') }
      end }
  end
end
