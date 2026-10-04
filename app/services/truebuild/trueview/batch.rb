# frozen_string_literal: true

module Truebuild
  module Trueview
    # A batch factory run's drawings, through Gemini's batch mode at half
    # price (GeminiBatch). The same decisions as an immediate drawing
    # (Trueview.prepare, the cut, the check, two Lite tries and then the
    # larger model), spread over batches instead of one call:
    #
    #   submit!  queued rows are prepared and sent as one batch per image model
    #   poll!    a finished batch's drawings are stored and each queued for
    #            TruebuildBatchDrawingJob, which cuts and checks it (check!)
    #   check!   passes it, holds it back, or queues it for the next batch
    #            with what the check found
    #
    # TruebuildFactoryRunTickJob calls submit! and poll! every few minutes.
    module Batch
      module_function

      SIZE = 120 # drawings per batch: each line carries the photo and its samples
      SUBMIT_TRIES = 3 # a row whose batch could not be sent is failed after this many

      def waiting(run)
        run.renders.where(status: 'queued').where("usage->>'batch' = 'true'")
      end

      STUCK_AFTER = 30.minutes

      # A deploy can stop a job halfway: drawings prepared but never sent go
      # back in line, and drawings Google returned but nobody checked are
      # checked. Returns the number recovered.
      def recover!(run)
        rows = run.renders.where(status: 'running').where("usage->>'batch' = 'true'").where(updated_at: ...STUCK_AFTER.ago)
        unsent = rows.where.not("usage ? 'batch_name'").where.not("usage ? 'batch_drawn'")
        unchecked = rows.where("usage ? 'batch_drawn'").to_a
        count = unsent.update_all(status: 'queued', updated_at: Time.current)
        unchecked.each do |r|
          r.touch
          TruebuildBatchDrawingJob.set(queue: :low).perform_later(r.id)
        end
        count + unchecked.size
      end

      # Sends what is waiting. Returns the number sent.
      def submit!(run)
        rows = waiting(run).order(:id).limit(SIZE).to_a
        return 0 if rows.empty?

        by_model = Hash.new { |h, k| h[k] = [] }
        rows.each do |render|
          render.update!(status: 'running', error: nil)
          ctx = Trueview.prepare(render) or next # not in the photo, or no outline yet: settled
          if render.usage['recut_from'] && render.image_url.present?
            # Already drawn under an older cut: cut again now, no image model.
            Trueview.recut!(render, ctx[:source], ctx[:mask], ctx[:check_with])
            next
          end
          spec_key = next_model(render)
          req = Providers::Gemini.request(MODELS.fetch(spec_key), ctx[:source], asked(render, ctx[:prompt], spec_key),
                                          samples: ctx[:samples], aspect: Trueview.source_aspect(ctx[:source]))
          render.update_columns(usage: render.usage.merge('batch_model' => spec_key, 'batch_box' => req[:box]))
          by_model[req[:model]] << ["r#{render.id}", req[:body], render]
        rescue StandardError => e
          render.update!(status: 'failed', error: "Not sent: #{e.message.to_s.first(500)}")
        end

        sent = 0
        by_model.each do |model, lines|
          name = GeminiBatch.submit(model, lines.map { |key, body, _| [key, body] }, display_name: "truebuild-run-#{run.id}-#{Time.now.to_i}")
          lines.each { |_, _, r| r.update_columns(usage: r.usage.merge('batch_name' => name), updated_at: Time.current) }
          run.reload # other jobs write progress (models queued, repairs)
          run.update!(progress: run.progress.merge('batches' => Array(run.progress['batches']) +
                                                   [{ 'name' => name, 'model' => model, 'count' => lines.size, 'at' => Time.current.iso8601 }]))
          sent += lines.size
        rescue StandardError => e
          Rails.logger.warn("TrueView batch submit for run #{run.id}: #{e.message}")
          lines.each { |_, _, r| unsent(r, e.message) }
        end
        sent
      end

      # Collects every finished batch of the run. Returns the drawings collected.
      def poll!(run)
        names = run.renders.where(status: 'running').where("usage ? 'batch_name'").distinct.pluck(Arel.sql("usage->>'batch_name'"))
        names.sum do |name|
          state = GeminiBatch.status(name)
          rows = run.renders.where(status: 'running').where("usage->>'batch_name' = ?", name).to_a
          if state[:failed]
            rows.each { |r| unsent(r, "Google's batch ended #{state[:state]}") }
            0
          elsif state[:done] && state[:responses_file]
            collect(rows, state[:responses_file])
          else
            0
          end
        rescue StandardError => e
          Rails.logger.warn("TrueView batch poll #{name}: #{e.message}")
          0
        end
      end

      def collect(rows, responses_file)
        drawn, errors = GeminiBatch.results(responses_file)
        rows.each do |render|
          key = "r#{render.id}"
          if (response = drawn[key])
            spec_key = render.usage['batch_model']
            result = Providers::Gemini.read(response, MODELS.fetch(spec_key)[:model], render.usage['batch_box'])
            cost = (Trueview.cost(MODELS.fetch(spec_key), result[:usage]) * GeminiBatch::DISCOUNT).round(4)
            url = Trueview.store(render, result[:bytes], result[:mime], suffix: "batch-#{render.usage['tries'].to_i}")
            render.update!(image_url: url, cost_usd: render.cost_usd.to_f + cost, model: result[:model] || render.model,
                           usage: render.usage.except('batch_name').merge(result[:usage]).merge('batch_drawn' => url))
            TruebuildBatchDrawingJob.set(queue: :low).perform_later(render.id)
          else
            unsent(render, errors[key] || 'No drawing came back')
          end
        rescue StandardError => e
          unsent(render, e.message)
        end
        rows.size
      end

      # Cuts and checks a drawing a batch returned, as perform! does. A
      # failure goes to the next batch with what the check found.
      def check!(render)
        drawn_url = render.usage['batch_drawn'] or return
        source = Trueview.fetch_source(render.source_url)
        mask = Surfaces.mask_for(render.source_url, source[:bytes], render.selection.first&.dig('surface'))
        ctx_check = check_with(render)
        drawn = Trueview.fetch_source(drawn_url)
        tries = render.usage['tries'].to_i + 1
        notes = Array(render.usage['notes'])
        if Trueview.reframed_by({ bytes: drawn[:bytes] }, Trueview.source_aspect(source)) > Trueview::FRAMING_TOLERANCE
          return again(render, tries, notes, nil) if tries < limit(render)

          return render.update!(status: 'failed', error: "The model changed the photo's framing #{tries} times")
        end

        layer = Layer.build(source[:bytes], drawn[:bytes], mask: Trueview.mask_image(mask), blocked: Trueview.blocked_image(mask, source[:bytes]))
        verdict = LayerCheck.judge(source[:bytes], layer[:bytes], surface: render.selection.first&.dig('surface'),
                                                                   value: render.selection.first&.dig('value'), **ctx_check)
        spent = render.cost_usd.to_f + verdict['cost_usd'].to_f
        notes << verdict['note'] if verdict['note'].present?
        return again(render, tries, notes, spent) if !verdict['ok'] && tries < limit(render)

        attrs = { status: 'done', cost_usd: spent.round(4), layer_url: Trueview.store(render, layer[:bytes], layer[:mime], suffix: 'layer'),
                  mask_coverage: layer[:coverage],
                  usage: render.usage.except('batch_drawn').merge('mask_version' => Layer::VERSION, 'check' => verdict.except('cost_usd'),
                                                                  'outlined' => mask.present?, 'tries' => tries, 'notes' => notes) }
        attrs[:usage]['escalated'] = true if render.usage['batch_model'] == ESCALATE_TO
        attrs.merge!(status: 'rejected', error: "Hidden: #{verdict['note'] || 'failed its check'}") unless verdict['ok']
        render.update!(attrs)
      end

      # Two Lite tries, then one on the larger model; a row sent to the
      # larger model to begin with gets that one try.
      def limit(render)
        render.usage['draw_with'] == ESCALATE_TO ? 1 : LAYER_ATTEMPTS + 1
      end

      def next_model(render)
        return ESCALATE_TO if render.usage['draw_with'] == ESCALATE_TO || render.usage['tries'].to_i >= LAYER_ATTEMPTS

        render.model_key
      end

      # The prompt, told what the checks found, as perform! tells it.
      def asked(render, prompt, spec_key)
        notes = Array(render.usage['notes'])
        return prompt if notes.empty?
        return "#{prompt}\n\nChecks of the earlier drawings found: #{notes.join(' ')} Fix all of that." if spec_key == ESCALATE_TO && spec_key != render.model_key

        "#{prompt}\n\nA check of the last drawing found: #{notes.last} Fix that."
      end

      def again(render, tries, notes, spent)
        render.update!(status: 'queued', cost_usd: (spent || render.cost_usd).to_f.round(4),
                       usage: render.usage.except('batch_drawn', 'batch_name').merge('tries' => tries, 'notes' => notes))
      end

      # Not sent, or not returned: waits for the next batch, a few times.
      def unsent(render, message)
        errors = render.usage['batch_errors'].to_i + 1
        if errors >= SUBMIT_TRIES
          render.update!(status: 'failed', error: "Batch: #{message.to_s.first(500)}")
        else
          render.update!(status: 'queued', usage: render.usage.except('batch_name').merge('batch_errors' => errors))
        end
      end

      def check_with(render)
        ids = Array(render.usage['swatch_ids'])
        swatches = CatalogSwatch.where(id: ids).index_by(&:id).values_at(*ids).compact
        sample = swatches.first && Trueview.fetch_source(swatches.first.image_url)
        { sample: sample&.dig(:bytes), hex: swatches.first&.hex }
      end
    end
  end
end
