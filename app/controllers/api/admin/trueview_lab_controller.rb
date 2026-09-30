# frozen_string_literal: true

# TrueView lab: one model photo, one set of finishes, every image model side
# by side with its time and cost. Platform admins only; it spends real money
# on the providers' accounts. Platform data, so no company scope.
class Api::Admin::TrueviewLabController < ApplicationController
  before_action :require_platform_admin!

  RENDER_ROOMS = %w[kitchen bath living bedroom dining laundry exterior].freeze
  MAX_FINISHES = 8
  MAX_LAYERS = 40

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

  # GET /api/admin/trueview_lab/drawn?variant_id=&source_url=&model=&room=
  # Layers already drawn for this photo and image model under the current
  # instructions: a new run reuses them at no cost.
  def drawn
    variant = CatalogPlanVariant.find_by(id: params[:variant_id])
    photo = variant && Array(variant.media['photos']).find { |p| p['url'] == params[:source_url].to_s }
    return render json: { finishes: [] } unless photo

    room = RENDER_ROOMS.include?(params[:room].to_s) ? params[:room].to_s : photo['room']
    rows = TruebuildRender.done.where(source_url: photo['url'], model_key: params[:model].to_s, purpose: 'layer')
                          .where.not(layer_url: nil).select(:selection, :prompt).to_a
    finishes = rows.select { |r| r.prompt == Truebuild::Trueview.prompt(room: room, selection: r.selection) }
                   .map { |r| r.selection.first.slice('surface', 'value') }.uniq
    render json: { finishes: finishes }
  end

  # POST /api/admin/trueview_lab/runs
  # Full redraw: { variant_id, source_url, room, finishes: [{surface, value}], models: [key], fresh }
  #   every image model draws the whole combination.
  # Layers: { mode: 'layers', variant_id, source_url, room, model: key, layers: [{surface, values: []}], fresh }
  #   one image model draws each finish on its own, cut out to stack.
  def create_run
    variant = CatalogPlanVariant.find_by(id: params[:variant_id])
    return render json: { error: 'Choose a model' }, status: :unprocessable_entity unless variant

    # Only the model's own photos: the job fetches this URL from the server.
    photo = Array(variant.media['photos']).find { |p| p['url'] == params[:source_url].to_s }
    return render json: { error: 'Choose one of this model\'s photos' }, status: :unprocessable_entity unless photo

    room = RENDER_ROOMS.include?(params[:room].to_s) ? params[:room].to_s : photo['room']
    jobs = params[:mode] == 'layers' ? layer_jobs : full_jobs
    return if performed?

    run = SecureRandom.uuid
    rows = jobs.map { |key, selection, purpose| build_render(variant, photo['url'], room, key, selection, purpose, run) }
    render json: run_json(run, rows), status: :created
  end

  private

  # [[model_key, selection, purpose]]
  def full_jobs
    selection = TruebuildRender.normalize(Array(params[:finishes]).map { |f| f.permit(:surface, :value).to_h }).first(MAX_FINISHES)
    return render(json: { error: 'Add at least one finish' }, status: :unprocessable_entity) && [] if selection.empty?

    keys = Array(params[:models]).map(&:to_s) & Truebuild::Trueview::MODELS.keys
    return render(json: { error: 'Choose at least one image model' }, status: :unprocessable_entity) && [] if keys.empty?

    keys.map { |key| [key, selection, 'full'] }
  end

  def layer_jobs
    key = params[:model].to_s
    unless Truebuild::Trueview::MODELS.key?(key)
      return render(json: { error: 'Choose an image model' }, status: :unprocessable_entity) && []
    end

    finishes = Array(params[:layers]).flat_map do |l|
      surface = l[:surface].to_s.strip
      Array(l[:values]).map { |v| { 'surface' => surface, 'value' => v.to_s.strip } }
    end
    finishes = TruebuildRender.normalize(finishes).uniq
    return render(json: { error: 'Add at least one finish' }, status: :unprocessable_entity) && [] if finishes.empty?
    if finishes.size > MAX_LAYERS
      return render(json: { error: "At most #{MAX_LAYERS} finishes per run" }, status: :unprocessable_entity) && []
    end

    finishes.map { |f| [key, [f], 'layer'] }
  end

  def build_render(variant, source_url, room, key, selection, purpose, run)
    spec = Truebuild::Trueview::MODELS[key]
    selection_key = TruebuildRender.key_for(selection)
    attrs = { catalog_plan_variant_id: variant.id, room: room, source_url: source_url, selection: selection,
              selection_key: selection_key, model_key: key, provider: spec[:provider], model: spec[:model], purpose: purpose,
              prompt: Truebuild::Trueview.prompt(room: room, selection: selection), lab_run: run }
    cached = !ActiveModel::Type::Boolean.new.cast(params[:fresh]) &&
             # Same prompt too: when the instructions improve, old drawings are not reused.
             TruebuildRender.done.where(source_url: source_url, selection_key: selection_key, model_key: key, purpose: purpose,
                                        prompt: attrs[:prompt])
                            .where(purpose == 'layer' ? 'layer_url IS NOT NULL' : 'TRUE').order(:id).last
    if cached
      # Served from the cache: what a buyer repeating this combination costs.
      TruebuildRender.create!(attrs.merge(status: 'done', image_url: cached.image_url, layer_url: cached.layer_url,
                                          mask_coverage: cached.mask_coverage, latency_ms: 0, cost_usd: 0,
                                          usage: { 'cached_from' => cached.id }, model: cached.model))
    elsif !Truebuild::Trueview.configured?(key)
      TruebuildRender.create!(attrs.merge(status: 'failed', error: "#{spec[:provider] == 'gemini' ? 'GEMINI' : 'OPENAI'}_API_KEY is not set"))
    else
      TruebuildRender.create!(attrs).tap { |r| TruebuildRenderJob.perform_later(r.id) }
    end
  end

  def run_json(run, rows)
    first = rows.first
    { id: run, mode: first.purpose == 'layer' ? 'layers' : 'full', created_at: first.created_at, variant_id: first.catalog_plan_variant_id, room: first.room,
      source_url: first.source_url, finishes: first.selection, prompt: first.prompt,
      total_cost_usd: rows.sum { |r| r.cost_usd.to_f }.round(4),
      renders: rows.map do |r|
        spec = Truebuild::Trueview::MODELS[r.model_key] || {}
        { id: r.id, model_key: r.model_key, label: spec[:label] || r.model_key, provider: r.provider, model: r.model,
          status: r.status, image_url: r.image_url, cost_usd: r.cost_usd&.to_f, latency_ms: r.latency_ms,
          usage: r.usage, error: r.error, cached: r.usage.is_a?(Hash) && r.usage.key?('cached_from'),
          purpose: r.purpose, layer_url: r.layer_url, mask_coverage: r.mask_coverage&.to_f,
          surface: r.selection.first&.dig('surface'), value: r.selection.first&.dig('value') }
      end }
  end
end
