# frozen_string_literal: true

require 'vips'

module Truebuild
  # TrueView: a model's real photo, redrawn by an image model in the finishes
  # the buyer picked. The room itself (walls, windows, cabinet runs, camera)
  # must stay as built, so the prompt asks for surface changes only and every
  # result is labelled a rendering wherever it is shown.
  #
  # Several image models are wired so they can be compared side by side on
  # our own photos (the TrueView lab). Prices are per million tokens, checked
  # 2026-09-30 from published rate cards; the cost shown is an estimate from
  # the token counts each provider reports, and the provider's billing page
  # is the truth.
  module Trueview
    module_function

    MODELS = {
      'nb2-lite' => { provider: 'gemini', model: 'gemini-3.1-flash-lite-image', label: 'Nano Banana 2 Lite',
                      rates: { input: 0.25, output: 30.0 }, size: nil },
      'nb2' => { provider: 'gemini', model: 'gemini-3.1-flash-image', label: 'Nano Banana 2',
                 rates: { input: 0.5, output: 60.0 }, size: '2K' },
      'nb-pro' => { provider: 'gemini', model: 'gemini-3-pro-image', label: 'Nano Banana Pro',
                    rates: { input: 2.0, output: 120.0 }, size: '2K' },
      'gpt-image-2-medium' => { provider: 'openai', model: 'gpt-image-2', label: 'GPT Image 2 (medium)', quality: 'medium',
                                rates: { text: 5.0, image: 8.0, output: 32.0 } },
      'gpt-image-2-high' => { provider: 'openai', model: 'gpt-image-2', label: 'GPT Image 2 (high)', quality: 'high',
                              rates: { text: 5.0, image: 8.0, output: 32.0 } }
    }.freeze

    class Error < StandardError; end

    def configured?(model_key)
      spec = MODELS[model_key] or return false
      ENV[spec[:provider] == 'gemini' ? 'GEMINI_API_KEY' : 'OPENAI_API_KEY'].present?
    end

    # What each surface covers. Left to itself a model reads "Cabinets" as
    # the wall cabinets but not the island, and "Accent wall" as a different
    # wall each time (or every wall), which breaks layers that must line up.
    SURFACE_SCOPE = [
      [/accent/i, 'An accent wall is ONE wall only: the single largest wall section facing the camera. Every other wall keeps its current color.'],
      [/cabinet|vanit|hw /i, 'Cabinets means every cabinet door, drawer front and cabinet box in the photo, including the island base, upper and lower cabinets, and the crown molding fitted on top of the cabinets, which matches them (not the crown molding where the walls meet the ceiling elsewhere). Countertops, walls and appliances stay exactly as they are. Keep every knob, pull, handle and hinge exactly as it is, the same number in the same places: never add hardware (a bath door drawn with a pull on each side).'],
      # These homes use a matching 4 inch laminate lip along the wall; left
      # alone it kept the old counter's pattern under a new counter.
      [/appliance/i, 'Appliances means the refrigerator, range, range hood or microwave and dishwasher: give them the finish and style the package names (stainless, black stainless, black, French door refrigerator), keeping their positions and sizes. Cabinets and countertops stay exactly as they are.'],
      [/counter/i, 'Countertops means every countertop surface, including the island top and the short matching backsplash lip of the same material along the wall. Cabinets, tile backsplash and walls stay exactly as they are.'],
      [/backsplash/i, 'Backsplash means only the wall surface between the countertop and the upper cabinets.'],
      [/floor|carpet/i, 'Flooring means only the visible floor.'],
      [/siding/i, 'Siding means only the exterior wall cladding. Trim, shutters, doors, windows, skirting and roof stay exactly as they are.'],
      [/shutter/i, 'Shutters means only the shutters beside the windows.'],
      [/shingle|roof/i, 'Shingles means only the roof surface.']
    ].freeze

    # The factory's own sample for each finish, where a decor sheet has one:
    # an array matching the normalized selection, nil where there is none.
    def swatches_for(variant, selection)
      return [] unless variant

      factory_id = variant.catalog_plan&.factory_id
      TruebuildRender.normalize(selection).map do |f|
        CatalogSwatch.for_finish(manufacturer_id: variant.manufacturer_id, factory_id: factory_id,
                                 surface: f['surface'], value: f['value'])
      end
    end

    # swatches: from swatches_for. A finish with a sample is drawn from the
    # sample image, sent after the room photo; the rest from name and color.
    def prompt(room:, selection:, swatches: [])
      shown = 0
      changes = TruebuildRender.normalize(selection).each_with_index.map do |f, i|
        swatch = swatches[i]
        if swatch
          shown += 1
          "- #{f['surface']}: #{f['value']}, exactly as in sample image #{shown + 1} (color #{swatch.hex})"
        else
          hex = ColorSwatches.hex(f['value'])
          "- #{f['surface']}: #{f['value']}#{" (color #{hex})" if hex}"
        end
      end
      scopes = TruebuildRender.normalize(selection).filter_map { |f| SURFACE_SCOPE.find { |re, _| f['surface'].match?(re) }&.last }.uniq
      place = room.present? ? "the #{room} of a manufactured home" : 'a room in a manufactured home'
      samples = if shown.positive?
                  "Image 1 is the room. The other images are flat samples of the actual finishes, cut from the factory's " \
                    'decor sheet: reproduce each sample\'s color, grain and pattern on its surface at a realistic scale, ' \
                    'with the room\'s own lighting and shadows.'
                end
      <<~TEXT.strip
        This is a real photograph of #{place}. Edit it so the finishes are:
        #{changes.join("\n")}
        #{scopes.join("\n")}
        #{samples}

        Match each listed color exactly where one is given. Change only those surfaces. Keep everything else exactly as it is: the room layout, walls, ceiling, windows, doors, cabinet and appliance positions and sizes, fixtures, lighting, camera position, lens and framing. Do not add, remove or move any object. The result must look like an unedited real estate photograph of the same room.
      TEXT
    end

    FRAMING_TOLERANCE = 0.04 # a drawing whose shape differs more than this was reframed
    DRAW_ATTEMPTS = 2        # per drawing, for framing
    LAYER_ATTEMPTS = 2       # drawings per layer, for its check (LayerCheck)

    def perform!(render)
      # A factory run's last repair round draws on a larger model; the row
      # stays keyed to the buyer's model so buyers find the layer.
      spec = MODELS.fetch(render.usage['draw_with'].presence || render.model_key)
      render.update!(status: 'running', error: nil)
      source = fetch_source(render.source_url)
      if render.purpose == 'layer'
        mask = Surfaces.mask_for(render.source_url, source[:bytes], render.selection.first&.dig('surface'))
        # The photo does not show this surface (no shutters on this home):
        # nothing to paint, and no drawing paid for.
        if mask && mask.status == 'done' && !mask.present?
          return render.update!(status: 'skipped', error: 'Not in this photo', cost_usd: 0,
                                usage: render.usage.merge('mask_version' => Layer::VERSION))
        end
        # Outlining this photo just failed on its shape: drawing would fail
        # the same way, and be paid for.
        if mask&.status == 'failed' && mask.error.to_s.include?('framing')
          return render.update!(status: 'failed', error: "Not drawn: #{mask.error}", cost_usd: 0)
        end
        # No outline yet: cut by what each drawing changed, every accent
        # color landed on a different wall. Drawn once the outline is found
        # (Surfaces retries it), never without one.
        if mask && mask.status != 'done'
          return render.update!(status: 'failed', error: "Not drawn: no outline yet (#{mask.error.to_s.first(200)})", cost_usd: 0)
        end
      end
      # The samples named when the row was made, in prompt order.
      ids = Array(render.usage['swatch_ids'])
      swatches = CatalogSwatch.where(id: ids).index_by(&:id).values_at(*ids).compact
      samples = swatches.map { |sw| fetch_source(sw.image_url) }
      # A layer changes one finish; its check compares against that sample.
      check_with = { sample: samples.first&.dig(:bytes), hex: swatches.first&.hex }
      prompt = render.prompt
      # A reviewer's note on what was wrong with the last drawing. Added at
      # draw time, not stored in the prompt, so buyers still find the layer.
      prompt = "#{prompt}\n\nA reviewer rejected an earlier drawing: #{render.usage['reviewer_note']} Fix that." if render.usage['reviewer_note'].present?
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      # A layer cut by an older Layer::VERSION is cut again from its saved
      # drawing: no call to the image model, no charge.
      return recut!(render, source, mask, check_with) if render.usage['recut_from'] && render.image_url.present?

      aspect = source_aspect(source)
      spent = 0.0
      result = layer = verdict = nil
      tries = draw_order(render, spec)
      notes = []
      escalated = false
      tries.each_with_index do |try_spec, attempt|
        asked = if try_spec.equal?(spec) || notes.empty?
                  verdict ? "#{prompt}\n\nA check of the last drawing found: #{verdict['note']} Fix that." : prompt
                else
                  "#{prompt}\n\nChecks of the earlier drawings found: #{notes.join(' ')} Fix all of that."
                end
        escalated ||= !try_spec.equal?(spec)
        result, drawn_cost = draw(try_spec, source, asked, samples, aspect)
        spent += drawn_cost
        unless result
          return render.update!(status: 'failed', cost_usd: spent.round(4),
                                error: "The model changed the photo's framing #{DRAW_ATTEMPTS} times")
        end
        break unless render.purpose == 'layer'

        layer = Layer.build(source[:bytes], result[:bytes], mask: mask_image(mask), blocked: blocked_image(mask, source[:bytes]))
        verdict = LayerCheck.judge(source[:bytes], layer[:bytes], surface: render.selection.first&.dig('surface'),
                                                                   value: render.selection.first&.dig('value'), **check_with)
        spent += verdict['cost_usd'].to_f
        notes << verdict['note'] if verdict['note'].present?
        break if verdict['ok'] || attempt == tries.size - 1
      end
      latency = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      url = store(render, result[:bytes], result[:mime])
      attrs = { status: 'done', image_url: url, latency_ms: latency, usage: render.usage.merge(result[:usage]),
                model: result[:model] || render.model, cost_usd: spent.round(4) }
      if render.purpose == 'layer'
        attrs.merge!(layer_url: store(render, layer[:bytes], layer[:mime], suffix: 'layer'), mask_coverage: layer[:coverage])
        attrs[:usage] = attrs[:usage].merge('mask_version' => Layer::VERSION, 'check' => verdict.except('cost_usd'), 'outlined' => mask.present?)
        attrs[:usage]['escalated'] = true if escalated
        # Failed every try: kept for review, never shown to buyers.
        attrs.merge!(status: 'rejected', error: "Hidden: #{verdict['note'] || 'failed its check'}") unless verdict['ok']
      end
      render.update!(attrs)
    rescue StandardError => e
      render.update!(status: 'failed', error: e.message.to_s.first(1000))
    end

    # Lite, twice, then once on the larger model with every note so far: a
    # Bay Port bath held back five of six countertops after two Lite tries.
    # A row already sent to the larger model is drawn on it once.
    ESCALATE_TO = 'nb2'

    def draw_order(render, spec)
      return [spec] unless render.purpose == 'layer'
      return [spec] if render.usage['draw_with'] == ESCALATE_TO

      [spec] * LAYER_ATTEMPTS + (spec.equal?(MODELS[ESCALATE_TO]) ? [] : [MODELS.fetch(ESCALATE_TO)])
    end

    # One drawing, redrawn if the model reframes the photo. [result, cost],
    # or [nil, cost] when it reframed every time.
    def draw(spec, source, prompt, samples, aspect)
      spent = 0.0
      DRAW_ATTEMPTS.times do
        result = if spec[:provider] == 'gemini'
                   Providers::Gemini.edit(spec, source, prompt, samples: samples, aspect: aspect)
                 else
                   Providers::OpenAi.edit(spec, source, prompt, samples: samples)
                 end
        spent += cost(spec, result[:usage])
        return [result, spent] if reframed_by(result, aspect) <= FRAMING_TOLERANCE
      end
      [nil, spent]
    end

    def recut!(render, source, mask = nil, check_with = {})
      drawn = fetch_source(render.image_url)
      if reframed_by({ bytes: drawn[:bytes] }, source_aspect(source)) > FRAMING_TOLERANCE
        # Drawn reframed before the check existed: draw it again instead.
        render.update!(status: 'queued', image_url: nil, usage: render.usage.except('recut_from'))
        return perform!(render)
      end
      layer = Layer.build(source[:bytes], drawn[:bytes], mask: mask_image(mask), blocked: blocked_image(mask, source[:bytes]))
      verdict = LayerCheck.judge(source[:bytes], layer[:bytes], surface: render.selection.first&.dig('surface'),
                                                                 value: render.selection.first&.dig('value'), **check_with)
      render.update!(status: verdict['ok'] ? 'done' : 'rejected', cost_usd: verdict['cost_usd'], latency_ms: 0,
                     mask_coverage: layer[:coverage], error: (verdict['ok'] ? nil : "Hidden: #{verdict['note'] || 'failed its check'}"),
                     layer_url: store(render, layer[:bytes], layer[:mime], suffix: "layer-v#{Layer::VERSION}"),
                     usage: render.usage.merge('mask_version' => Layer::VERSION, 'check' => verdict.except('cost_usd'), 'outlined' => mask.present?))
    end

    def source_aspect(source)
      img = Vips::Image.new_from_buffer(source[:bytes], '')
      img.width.to_f / img.height
    end

    # How far a drawing's shape is from the photo's, as a share.
    def reframed_by(result, aspect)
      img = Vips::Image.new_from_buffer(result[:bytes], '')
      ((img.width.to_f / img.height) / aspect - 1).abs
    end

    def mask_image(mask)
      return nil unless mask&.present?

      Vips::Image.new_from_buffer(fetch_source(mask.mask_url)[:bytes], '')
    end

    # What surfaces that outrank this one hold in the photo (Surfaces::PRECEDENCE),
    # kept out of the layer even where its own outline, made first, took it.
    def blocked_image(mask, source_bytes)
      return nil unless mask&.present?

      size = Vips::Image.new_from_buffer(source_bytes, '')
      Surfaces.claimed_above(mask.source_url, mask.surface, size.width, size.height)
    end

    def store_bytes(bytes, mime, key)
      s3 = S3UploadService.new
      s3.s3_client.put_object(bucket: s3.bucket_name, key: key, body: bytes, content_type: mime)
      "https://#{s3.bucket_name}.s3.#{s3.region}.amazonaws.com/#{key}"
    end

    def cost(spec, usage)
      r = spec[:rates]
      u = usage.to_h.stringify_keys
      if spec[:provider] == 'gemini'
        (u['prompt_tokens'].to_i * r[:input] + u['output_tokens'].to_i * r[:output]) / 1_000_000.0
      else
        (u['text_tokens'].to_i * r[:text] + u['image_tokens'].to_i * r[:image] + u['output_tokens'].to_i * r[:output]) / 1_000_000.0
      end.round(4)
    end

    # Only photos already on the model are rendered, fetched at a size the
    # models work well with. Champion serves them from scene7.
    def fetch_source(url)
      res = HTTParty.get(sized(url), timeout: 30)
      raise Error, "Source photo returned #{res.code}" unless res.code == 200

      { bytes: res.body, mime: res.headers['content-type'].presence || 'image/jpeg' }
    end

    # The exact image layers are cut against; a page stacking layers must
    # show this one underneath or they will not line up.
    def sized(url)
      url.include?('scene7.com') && !url.include?('?') ? "#{url}?wid=1600&fmt=jpeg&qlt=90" : url
    end

    def store(render, bytes, mime, suffix: nil)
      ext = { 'png' => 'png', 'webp' => 'webp' }.find { |k, _| mime.to_s.include?(k) }&.last || 'jpg'
      s3 = S3UploadService.new
      key = "truebuild/trueview/#{render.selection_key}-#{render.model_key}-#{render.id}#{"-#{suffix}" if suffix}.#{ext}"
      s3.s3_client.put_object(bucket: s3.bucket_name, key: key, body: bytes, content_type: mime)
      "https://#{s3.bucket_name}.s3.#{s3.region}.amazonaws.com/#{key}"
    end
  end
end
