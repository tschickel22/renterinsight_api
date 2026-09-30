# frozen_string_literal: true

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
      [/cabinet|vanit|hw /i, 'Cabinets means every cabinet door, drawer front and cabinet box in the photo, including the island base, upper and lower cabinets. Countertops, walls and appliances stay exactly as they are.'],
      [/counter/i, 'Countertops means every countertop surface, including the island top. Cabinets, backsplash and walls stay exactly as they are.'],
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

    def perform!(render)
      spec = MODELS.fetch(render.model_key)
      render.update!(status: 'running', error: nil)
      source = fetch_source(render.source_url)
      # The samples named when the row was made, in prompt order.
      ids = Array(render.usage['swatch_ids'])
      samples = CatalogSwatch.where(id: ids).index_by(&:id).values_at(*ids).compact.map { |sw| fetch_source(sw.image_url) }
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = if spec[:provider] == 'gemini'
                 Providers::Gemini.edit(spec, source, render.prompt, samples: samples)
               else
                 Providers::OpenAi.edit(spec, source, render.prompt, samples: samples)
               end
      latency = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      url = store(render, result[:bytes], result[:mime])
      attrs = { status: 'done', image_url: url, latency_ms: latency, usage: render.usage.merge(result[:usage]),
                model: result[:model] || render.model, cost_usd: cost(spec, result[:usage]) }
      if render.purpose == 'layer'
        layer = Layer.build(source[:bytes], result[:bytes])
        attrs.merge!(layer_url: store(render, layer[:bytes], layer[:mime], suffix: 'layer'), mask_coverage: layer[:coverage])
      end
      render.update!(attrs)
    rescue StandardError => e
      render.update!(status: 'failed', error: e.message.to_s.first(1000))
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
      sized = url.include?('scene7.com') && !url.include?('?') ? "#{url}?wid=1600&fmt=jpeg&qlt=90" : url
      res = HTTParty.get(sized, timeout: 30)
      raise Error, "Source photo returned #{res.code}" unless res.code == 200

      { bytes: res.body, mime: res.headers['content-type'].presence || 'image/jpeg' }
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
