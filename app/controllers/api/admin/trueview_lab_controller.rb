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

    # The factory's decor sheet samples first (they carry a picture), then
    # the price book's named colors.
    factory_id = variant.catalog_plan&.factory_id
    samples = CatalogSwatch.where(manufacturer_id: variant.manufacturer_id, factory_id: [factory_id, nil].uniq)
                           .pluck(:set_name, :name)
                           .group_by(&:first)
                           .map { |set, rows| { name: set, values: rows.map(&:last).uniq.sort, samples: true } }
                           .sort_by { |s| s[:name] }
    colors = CatalogOption.where(manufacturer_id: variant.manufacturer_id, kind: 'color', status: 'active')
                          .pluck(:name, Arel.sql("metadata->>'color_set'"))
                          .group_by { |_, set| set.presence || 'Colors' }
                          .map { |set, rows| { name: set, values: rows.map(&:first).uniq.sort.first(60), samples: false } }
                          .sort_by { |s| s[:name] }
    render json: { sets: samples + colors.reject { |c| samples.any? { |s| s[:name].casecmp?(c[:name]) } } }
  end

  # GET /api/admin/trueview_lab/review?variant_id=
  # What buyers see for a model, to check: each photo's surface outlines
  # (with Claude's score and note) and every layer drawn on it.
  def review
    variant = CatalogPlanVariant.find_by(id: params[:variant_id])
    return render json: { error: 'Choose a model' }, status: :unprocessable_entity unless variant

    photos = Array(variant.media['photos']).select { |p| Truebuild::Trueview::Buyer::ROOMS.key?(p['room']) }
                                          .uniq { |p| p['room'] }
    render json: {
      variant: { id: variant.id, name: variant.media['name'].presence || variant.model_number },
      photos: photos.map do |p|
        masks = TruebuildSurfaceMask.where(source_url: p['url'], version: Truebuild::Trueview::Surfaces::VERSION).order(:surface)
        layers = TruebuildRender.where(source_url: p['url'], purpose: 'layer', model_key: Truebuild::Trueview::Buyer::MODEL)
                                .where.not(status: 'superseded').order(:id)
                                .select { |r| r.status != 'done' || r.usage['mask_version'].to_i >= Truebuild::Trueview::Layer::VERSION }
                                .group_by(&:selection_key).map { |_, rs| rs.last }
        { room: p['room'], url: Truebuild::Trueview.sized(p['url']),
          outlines: masks.map do |m|
            last = Array(m.usage['attempts']).last || {}
            { id: m.id, surface: m.surface, status: m.status, used: m.present?, coverage: m.coverage&.to_f, mask_url: m.mask_url,
              fit: last['fit'], present: last['present'], note: m.error, cost_usd: m.usage['cost_usd'] }
          end,
          layers: layers.map do |r|
            { id: r.id, surface: r.selection.first&.dig('surface'), value: r.selection.first&.dig('value'), status: r.status,
              layer_url: r.layer_url, image_url: r.image_url, coverage: r.mask_coverage&.to_f, error: r.error,
              reviewer_note: r.usage['reviewer_note'], cost_usd: r.cost_usd&.to_f }
          end }
      end
    }
  end

  # POST /api/admin/trueview_lab/layers/:id/flag { note }
  # Buyers stop seeing the layer at once; it is drawn again with the note.
  def flag_layer
    row = TruebuildRender.find_by(id: params[:id], purpose: 'layer')
    return render json: { error: 'Not found' }, status: :not_found unless row

    note = params[:note].to_s.strip.first(500)
    row.update!(status: 'flagged', error: note.presence || 'Flagged by a reviewer')
    again = TruebuildRender.create!(row.attributes.except('id', 'created_at', 'updated_at', 'layer_url', 'mask_coverage', 'image_url',
                                                         'cost_usd', 'latency_ms', 'error', 'lab_run')
                                      .merge('status' => 'queued',
                                             'usage' => row.usage.slice('swatch_ids', 'predraw').merge('reviewer_note' => note, 'flagged_from' => row.id)))
    TruebuildRenderJob.perform_later(again.id)
    render json: { flagged: row.id, redraw: again.id }
  end

  # POST /api/admin/trueview_lab/outlines/:id/flag { note }
  # Outlines the surface again with the note, then cuts its layers again.
  def flag_outline
    mask = TruebuildSurfaceMask.find_by(id: params[:id])
    return render json: { error: 'Not found' }, status: :not_found unless mask

    TruebuildOutlineRedoJob.perform_later(mask.id, params[:note].to_s.strip.first(500))
    render json: { queued: mask.id }
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
    finishes = rows.select do |r|
      r.prompt == Truebuild::Trueview.prompt(room: room, selection: r.selection, swatches: Truebuild::Trueview.swatches_for(variant, r.selection))
    end
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
    swatches = Truebuild::Trueview.swatches_for(variant, selection)
    attrs = { catalog_plan_variant_id: variant.id, room: room, source_url: source_url, selection: selection,
              selection_key: selection_key, model_key: key, provider: spec[:provider], model: spec[:model], purpose: purpose,
              prompt: Truebuild::Trueview.prompt(room: room, selection: selection, swatches: swatches), lab_run: run,
              usage: { 'swatch_ids' => swatches.compact.map(&:id) } }
    cached = !ActiveModel::Type::Boolean.new.cast(params[:fresh]) &&
             # Same prompt too: when the instructions improve, old drawings are not reused.
             TruebuildRender.done.where(source_url: source_url, selection_key: selection_key, model_key: key, purpose: purpose,
                                        prompt: attrs[:prompt])
                            .where(purpose == 'layer' ? 'layer_url IS NOT NULL' : 'TRUE').order(:id).last
    if cached && purpose == 'layer' && cached.usage['mask_version'].to_i < Truebuild::Trueview::Layer::VERSION
      # Drawn already but cut by an older version: cut again from the saved drawing, free.
      TruebuildRender.create!(attrs.merge(image_url: cached.image_url, model: cached.model,
                                          usage: attrs[:usage].merge('recut_from' => cached.id)))
                     .tap { |r| TruebuildRenderJob.perform_later(r.id) }
    elsif cached
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
