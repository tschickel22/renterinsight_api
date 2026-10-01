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
          photos: Array(v.shown_media['photos']).select { |p| p['url'].present? }.map { |p| p.slice('url', 'room') } }
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

    choice = Truebuild::Trueview::PhotoChoice
    media = variant.media || {}
    photos = choice.photos(variant).map { |room, url| { 'room' => room, 'url' => url } }
    requeue_stale(photos.map { |p| p['url'] })
    render json: {
      variant: { id: variant.id, name: variant.media['name'].presence || variant.model_number },
      # Which photos TrueView uses per room, how they were chosen, and every
      # photo that could be used instead (the room's own first).
      rooms: choice::ROOMS.map do |room|
        labelled = choice.candidate_urls(media, room)
        others = choice.candidate_urls(media, room, all: true) - labelled
        { room: room, chosen: choice.chosen(media, room), source: choice.source(media, room),
          candidates: (labelled + others).map { |u| { url: u, thumb: Truebuild::Trueview.sized(u), labelled: labelled.include?(u) } } }
      end,
      # Every photo and elevation on the model, hidden ones included, to hide
      # or bring back.
      gallery: gallery_urls(media).map do |url, room|
        { url: url, thumb: Truebuild::Trueview.sized(url), room: room, hidden: variant.hidden_photo_urls.include?(url) }
      end,
      photos: photos.map do |p|
        masks = TruebuildSurfaceMask.where(source_url: p['url'], version: Truebuild::Trueview::Surfaces::VERSION).order(:surface)
        layers = TruebuildRender.where(source_url: p['url'], purpose: 'layer', model_key: Truebuild::Trueview::Buyer::MODEL)
                                .where.not(status: 'superseded').order(:id)
                                .select { |r| r.status != 'done' || r.usage['mask_version'].to_i >= Truebuild::Trueview::Layer::VERSION }
                                .group_by(&:selection_key).map { |_, rs| rs.last }
        { room: p['room'], url: Truebuild::Trueview.sized(p['url']), source_url: p['url'],
          outlines: masks.map do |m|
            last = Array(m.usage['attempts']).last || {}
            { id: m.id, surface: m.surface, status: m.status, used: m.present?, coverage: m.coverage&.to_f, mask_url: m.mask_url,
              fit: last['fit'], present: last['present'], note: m.error, cost_usd: m.usage['cost_usd'] }
          end,
          layers: layers.map do |r|
            { id: r.id, surface: r.selection.first&.dig('surface'), value: r.selection.first&.dig('value'), status: r.status,
              layer_url: r.layer_url, image_url: r.image_url, coverage: r.mask_coverage&.to_f, error: r.error,
              reviewer_note: r.usage['reviewer_note'], cost_usd: r.cost_usd&.to_f,
              check: r.usage['check'], approved: r.usage['approved'].present? }
          end }
      end
    }
  end

  # POST /api/admin/trueview_lab/photos { variant_id, room, urls: [] }
  # The photos TrueView uses for a room, in order (empty: back to Claude's
  # pick). New photos are drawn the next time a buyer opens the model.
  def choose_photos
    variant = CatalogPlanVariant.find_by(id: params[:variant_id])
    return render json: { error: 'Choose a model' }, status: :unprocessable_entity unless variant

    choice = Truebuild::Trueview::PhotoChoice
    room = params[:room].to_s
    return render json: { error: 'Unknown room' }, status: :unprocessable_entity unless choice::ROOMS.include?(room)

    media = variant.media || {}
    allowed = choice.candidate_urls(media, room, all: true)
    urls = Array(params[:urls]).map(&:to_s).select { |u| allowed.include?(u) }.uniq.first(choice::MAX)
    picks = (media['trueview_photos'] || {}).merge(room => urls)
    variant.update_columns(media: media.merge('trueview_photos' => picks.reject { |_, v| v.blank? }))
    # The next buyer visit draws for the new photos.
    Rails.cache.delete("truebuild:trueview:predraw:#{variant.id}:v#{Truebuild::Trueview::Layer::VERSION}")
    render json: { room: room, chosen: choice.chosen(variant.reload.media, room), source: choice.source(variant.media, room) }
  end

  # POST /api/admin/trueview_lab/photos/hide { variant_id, url, hidden }
  # A photo hidden from buyers everywhere: the designer, the model list,
  # inventory cards and TrueView. Kept by URL, so a rescan does not bring it
  # back but a new photo from the factory still shows.
  def hide_photo
    variant = CatalogPlanVariant.find_by(id: params[:variant_id])
    return render json: { error: 'Choose a model' }, status: :unprocessable_entity unless variant

    media = variant.media || {}
    url = params[:url].to_s
    return render json: { error: 'Not a photo of this model' }, status: :unprocessable_entity unless gallery_urls(media).key?(url)

    hide = ActiveModel::Type::Boolean.new.cast(params[:hidden])
    hidden = variant.hidden_photo_urls - [url]
    hidden << url if hide
    media = media.merge('hidden_photos' => hidden)
    if hide
      # A hidden photo stops being drawn on; Claude picks the room again.
      media['trueview_photos'] = (media['trueview_photos'] || {}).transform_values { |urls| Array(urls) - [url] }.reject { |_, v| v.blank? }
      media['trueview_auto'] = (media['trueview_auto'] || {}).reject { |_, v| v == url }
    end
    # updated_at moves the model list's cache key.
    variant.update_columns(media: media, updated_at: Time.current)
    Rails.cache.delete("truebuild:trueview:predraw:#{variant.id}:v#{Truebuild::Trueview::Layer::VERSION}")
    render json: { url: url, hidden: hide }
  end

  # POST /api/admin/trueview_lab/layers/:id/approve
  # A layer its check held back, shown to buyers after all.
  def approve_layer
    row = TruebuildRender.find_by(id: params[:id], purpose: 'layer', status: 'rejected')
    return render json: { error: 'Not found' }, status: :not_found unless row

    row.update!(status: 'done', error: nil, usage: row.usage.merge('approved' => { 'by' => current_user&.id, 'at' => Time.current.iso8601 }))
    render json: { approved: row.id }
  end

  # GET /api/admin/trueview_lab/attention
  # Models with something to look at, worst first: layers held back by their
  # check, outlines not used though the surface is there, drawings that failed.
  def attention
    version = Truebuild::Trueview::Layer::VERSION
    rows = TruebuildRender.where(purpose: 'layer', model_key: Truebuild::Trueview::Buyer::MODEL)
                          .where(status: %w[rejected failed]).where.not(catalog_plan_variant_id: nil)
                          .where("(usage->>'mask_version')::int >= ? OR status = 'failed'", version)
                          .group(:catalog_plan_variant_id, :status).count
    outlines = TruebuildSurfaceMask.where(version: Truebuild::Trueview::Surfaces::VERSION, status: 'done', coverage: 0)
                                   .where("usage->'presence'->>'present' = 'true' OR usage->'attempts'->-1->>'present' = 'true'")
                                   .pluck(:source_url)
    by_photo = CatalogPlanVariant.where("jsonb_array_length(COALESCE(media->'photos', '[]'::jsonb)) > 0").pluck(:id, :media)
    outline_counts = Hash.new(0)
    by_photo.each do |id, media|
      urls = Array(media['photos']).map { |p| p['url'] }
      outline_counts[id] += outlines.count { |u| urls.include?(u) }
    end
    ids = (rows.keys.map(&:first) + outline_counts.select { |_, n| n.positive? }.keys).uniq
    names = CatalogPlanVariant.where(id: ids).pluck(:id, Arel.sql("media->>'name'"), :model_number).to_h { |i, n, m| [i, n.presence || m] }
    items = ids.map do |id|
      { variant_id: id, name: names[id], held_back: rows[[id, 'rejected']].to_i, failed: rows[[id, 'failed']].to_i,
        outlines_not_used: outline_counts[id] }
    end
    render json: { items: items.sort_by { |i| -(i[:held_back] * 2 + i[:failed] + i[:outlines_not_used]) } }
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

  # Drawings left 'queued' or 'running' for 15 minutes were lost (a deploy
  # restarted the worker); opening the review puts them back on the queue.
  # url => room (nil for elevations), photos first.
  def gallery_urls(media)
    photos = Array(media['photos']).select { |p| p['url'].present? }.to_h { |p| [p['url'], p['room']] }
    Array(media['elevations']).compact.each { |u| photos[u] ||= nil }
    photos
  end

  def requeue_stale(source_urls)
    scope = TruebuildRender.where(source_url: source_urls, purpose: 'layer')
    TruebuildRenderJob.orphaned(scope, stale_after: Truebuild::Trueview::Buyer::STALE_AFTER)
                      .each { |row| TruebuildRenderJob.requeue(row) }
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
