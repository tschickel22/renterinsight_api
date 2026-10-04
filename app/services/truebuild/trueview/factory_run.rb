# frozen_string_literal: true

module Truebuild
  module Trueview
    # Draws every finish in the price book on every model of a factory (or one
    # series) ahead of buyers, once for every dealer who sells those models.
    #
    # Nothing is paid for twice. A drawing is stored by photo and finish and an
    # outline by photo and surface, so a model two factories carry with the
    # same photos is drawn once, and Claude's photo pick is reused for it
    # (PhotoChoice.picked_elsewhere). A model with no photos costs nothing.
    # Drawings are kept in S3 with no expiry.
    module FactoryRun
      module_function

      PRIORITY = 10 # behind buyers' own drawings (0) in the same queue
      LAYER_COST = 0.04 # per drawing until enough have been measured
      RECUT_COST = 0.012 # an existing drawing cut again on a newer outline: only its check is paid
      OUTLINE_COST = 0.06

      # Active models of the scope that a published price book prices.
      def variants(manufacturer_id:, factory_id: nil, series: nil)
        priced = CatalogVariantPrice.where(catalog_price_book_id: CatalogPriceBook.published.select(:id)).select(:catalog_plan_variant_id)
        scope = CatalogPlanVariant.active.where(manufacturer_id: manufacturer_id, id: priced)
                                  .joins(:catalog_plan).includes(:catalog_plan)
        scope = scope.where(catalog_plans: { factory_id: factory_id }) if factory_id.present?
        scope = scope.where(catalog_plans: { series: series }) if series.present?
        scope.order('catalog_plans.series', 'catalog_plans.name', :model_number).to_a
      end

      # What a run would draw and cost, per model and in total. Drawings one
      # model shares with another earlier in the list are counted once.
      # batch: priced at Gemini's batch rate (GeminiBatch::DISCOUNT).
      def estimate(variants, batch: false)
        rates = self.rates(batch: batch)
        seen = Set.new
        outlined = Set.new
        # Which are drawn and on dealer sites already, and when a run last
        # took each, so a run of a few models does not redo the same ones.
        on_sites = ModelList.trueview_ready(variants.map(&:id))
        last_run = last_runs
        models = variants.map do |v|
          cost = model_cost(v, rates, seen, outlined)
          { id: v.id, name: name(v), model_number: v.model_number, series: v.catalog_plan&.series,
            on_sites: on_sites.include?(v.id), last_run_at: last_run[v.id] }.merge(cost)
        end
        drawings = models.sum { |m| m[:drawings] }
        outlines = models.sum { |m| m[:outlines] }
        { models: models,
          totals: { models: models.size, with_photos: models.count { |m| m[:photos].positive? },
                    drawings: drawings, recuts: models.sum { |m| m[:recuts].to_i }, shared: models.sum { |m| m[:shared] },
                    already_drawn: models.sum { |m| m[:already_drawn] }, outlines: outlines,
                    cost_usd: models.sum { |m| m[:cost_usd] }.round(2) },
          rates: rates }
      end

      # A drawing a run made: a batch run's waits for its next batch
      # (Batch.submit!), any other is drawn now, behind buyers.
      def dispatch(row, run)
        if run&.batch?
          row.update_columns(usage: row.usage.merge('batch' => true))
        else
          TruebuildRenderJob.set(queue: :low, priority: PRIORITY).perform_later(row.id)
        end
      end

      # variant id => when the latest run that included it started.
      def last_runs
        TruebuildFactoryRun.order(:created_at).pluck(:variant_ids, :created_at)
                           .each_with_object({}) { |(ids, at), h| Array(ids).each { |id| h[id.to_i] = at } }
      end

      # at: when to start (nil or past: now). batch: draw through Gemini's
      # batch mode. A scheduled run waits; TruebuildFactoryRunTickJob starts it.
      def start!(variants, budget_usd:, scope:, by: nil, at: nil, batch: false)
        later = at.present? && at > 1.minute.from_now
        run = TruebuildFactoryRun.create!(manufacturer_id: scope[:manufacturer_id], factory_id: scope[:factory_id].presence,
                                          series: scope[:series].presence, budget_usd: budget_usd, created_by_id: by&.id,
                                          variant_ids: variants.map(&:id), estimate: estimate(variants, batch: batch)[:totals],
                                          mode: batch ? 'batch' : 'now', status: later ? 'scheduled' : 'running',
                                          scheduled_at: later ? at : nil)
        TruebuildFactoryRunJob.perform_later(run.id) unless later
        run
      end

      # A scheduled run whose time has come.
      def begin!(run)
        return unless run.status == 'scheduled'

        run.update!(status: 'running')
        TruebuildFactoryRunJob.perform_later(run.id)
      end

      # Model by model: Claude picks its photos if nobody has, then every
      # missing drawing is queued. Stops before a model that would go over
      # budget, and when stopped.
      def queue!(run)
        rates = self.rates(batch: run.batch?)
        # Outlines are made as drawings run, so a later model with the same
        # photo must not be charged for one an earlier model has queued.
        seen = Set.new
        outlined = Set.new
        run.variant_ids.each_with_index do |id, i|
          next if i < run.models_queued

          return unless run.reload.status == 'running'

          variant = CatalogPlanVariant.find_by(id: id)
          # What was actually spent, when retries made it more than the
          # estimate: Aspire's first run spent $5.75 of a $5 budget.
          committed = [run.committed_usd, run.spent_usd].max
          if variant && Array(variant.shown_media['photos']).any?
            PhotoChoice.pick!(variant) if PhotoChoice.needs_pick?(variant)
            variant.reload
            cost = model_cost(variant, rates, seen, outlined)
            if committed + cost[:cost_usd] > run.budget_usd.to_f
              run.update!(status: 'budget_reached', stopped_at: Time.current)
              run.notify_end
              return
            end
            Buyer.new(nil, variant).queue_missing!(run: run)
            committed += cost[:cost_usd]
          end
          run.update!(progress: run.progress.merge('models_queued' => i + 1, 'committed_usd' => committed.round(2)))
        end
      end

      # Once a run's drawings are all done, what failed gets another round:
      # an outline Claude rejected is outlined again with its note, a
      # drawing held back by its check is drawn again with every note so
      # far, on the larger image model (every drawing already had two Lite
      # tries and one on the larger model, Trueview.draw_order). All within the
      # run's budget. Lite drew Bay Port's porch wall half in the old siding
      # twice; held back for good, a buyer simply never saw that finish.
      REPAIR_ROUNDS = 2
      STRONGER = Trueview::ESCALATE_TO # Nano Banana 2: about twice Lite's cost, and steadier

      # Called as each of a run's drawings finishes.
      def drawing_finished!(run)
        return unless run.status == 'running' && run.models_queued >= run.variant_ids.size
        return if run.renders.where(status: %w[queued running]).exists?

        run.with_lock do
          round = run.progress['repair_rounds'].to_i
          return finish!(run) if round >= REPAIR_ROUNDS
          return if run.progress['repair_queued'].to_i > round

          run.update!(progress: run.progress.merge('repair_queued' => round + 1))
        end
        TruebuildFactoryRunRepairJob.perform_later(run.id)
      end

      # One round. Returns the number of drawings queued again.
      def repair!(run)
        round = run.progress['repair_rounds'].to_i + 1
        rates = self.rates(batch: run.batch?)
        spent = run.spent_usd
        variants = CatalogPlanVariant.where(id: run.variant_ids).to_a
        photos = variants.flat_map { |v| PhotoChoice.photos(v).map(&:last) }.uniq

        # Outlines worth another try are only marked due here; each is
        # outlined again inside the drawing jobs queued below (Surfaces.mask_for),
        # in parallel. Outlining them all in this job took many minutes, and a
        # worker restart ran it twice over the same outlines.
        failed_outlines(photos).each { |mask| Surfaces.make_due!(mask) }

        queued = 0
        held = run.renders.where(status: 'rejected').to_a.select { |r| r.usage['mask_version'].to_i >= Layer::VERSION }
        passed = run.renders.done.where(source_url: held.map(&:source_url)).pluck(:source_url, :selection_key, :prompt).to_set
        cost = rates[:layer] * 2 # on the larger model
        held.each do |old|
          next if passed.include?([old.source_url, old.selection_key, old.prompt])
          break if spent + cost > run.budget_usd.to_f

          old.update!(status: 'superseded')
          row = TruebuildRender.create!(
            old.attributes.slice('catalog_plan_variant_id', 'room', 'source_url', 'selection', 'selection_key', 'model_key',
                                 'provider', 'model', 'purpose', 'prompt')
               .merge('status' => 'queued',
                      'usage' => old.usage.slice('swatch_ids', 'predraw', 'factory_run_id')
                                   .merge('reviewer_note' => notes(old), 'repair_round' => round,
                                          'draw_with' => STRONGER).compact)
          )
          dispatch(row, run)
          spent += cost
          queued += 1
        end
        # Drawings that waited on an outline, now there is one.
        seen = Set.new
        outlined = Set.new
        variants.each do |v|
          # Counted as shared only once a model that shares it was queued.
          trial_seen = seen.dup
          trial_outlined = outlined.dup
          cost = model_cost(v, rates, trial_seen, trial_outlined)[:cost_usd]
          next if spent + cost > run.budget_usd.to_f

          seen = trial_seen
          outlined = trial_outlined
          queued += Buyer.new(nil, v).queue_missing!(run: run)
          spent += cost
        end

        run.update!(progress: run.progress.merge('repair_rounds' => queued.zero? ? REPAIR_ROUNDS : round,
                                                 'repaired' => run.progress['repaired'].to_i + queued))
        finish!(run) if queued.zero?
        queued
      end

      # Outlines worth another try: one that errored (not on framing, which
      # fails the same way again), and one Claude found the surface in but
      # rejected the outline of. That one is stored as no outline, so every
      # color of the surface was skipped as not in the photo.
      def failed_outlines(photos)
        TruebuildSurfaceMask.where(source_url: photos, version: Surfaces::VERSION).select do |m|
          if m.status == 'failed' then !m.error.to_s.include?('framing')
          else Surfaces.rejected?(m) && m.usage['tries'].to_i + 1 < Surfaces::OUTLINE_TRIES
          end
        end
      end

      # Every note the checks and reviewers have made on this photo and
      # finish, so a new drawing is told all of what went wrong, not just the last.
      def notes(render)
        [render.usage['reviewer_note'], render.usage.dig('check', 'note')].compact_blank.uniq.join(' Also: ')
      end

      LOST_AFTER = 15.minutes # a deploy restarts the workers; a job this quiet was lost

      def finish!(run)
        run.update!(status: 'finished', stopped_at: Time.current)
        run.notify_end
      end

      # A deploy can drop a run's jobs: the model queuing stops partway, or
      # drawings wait for ever. Each is put back on the queue where it stopped.
      def resume_lost(run)
        if run.models_queued < run.variant_ids.size && run.updated_at < LOST_AFTER.ago
          run.touch
          TruebuildFactoryRunJob.perform_later(run.id)
        end
        TruebuildRenderJob.orphaned(run.renders, stale_after: LOST_AFTER)
                          .each { |row| TruebuildRenderJob.requeue(row, queue: :low) }
        # A repair round queued but never done (its job was dropped).
        if run.progress['repair_queued'].to_i > run.progress['repair_rounds'].to_i && run.updated_at < LOST_AFTER.ago &&
           !run.renders.where(status: %w[queued running]).exists?
          run.touch
          TruebuildFactoryRunRepairJob.perform_later(run.id)
        end
      end

      # Where a run stands, from its drawings.
      def progress(run)
        resume_lost(run) if run.status == 'running'
        counts = run.renders.group(:status).count
        open = counts.values_at('queued', 'running').compact.sum
        repair_queued = run.progress['repair_queued'].to_i
        at_google = run.batch? && run.renders.where(status: 'running').where("usage ? 'batch_name'").exists?
        phase = if run.status != 'running' then run.status
                elsif run.models_queued < run.variant_ids.size then 'queuing'
                elsif at_google then 'waiting_on_google'
                elsif open.positive? then repair_queued.positive? ? 'repairing' : 'drawing'
                elsif repair_queued > run.progress['repair_rounds'].to_i then 'repairing'
                else 'finished'
                end
        # Nothing left to draw or repair: the run is over. Until this, a run
        # stayed "running" for ever and blocked the next run of its scope.
        finish!(run) if phase == 'finished' && run.status == 'running' && run.updated_at < LOST_AFTER.ago
        { id: run.id, phase: phase, manufacturer: run.manufacturer&.name, factory_id: run.factory_id, series: run.series,
          budget_usd: run.budget_usd.to_f, committed_usd: run.committed_usd, spent_usd: run.spent_usd.round(2),
          models: run.variant_ids.size, models_queued: run.models_queued, estimate: run.estimate,
          repair: { rounds: run.progress['repair_rounds'].to_i, redrawn: run.progress['repaired'].to_i },
          drawings: { done: counts['done'].to_i, held_back: counts['rejected'].to_i, not_in_photo: counts['skipped'].to_i,
                      failed: counts['failed'].to_i, waiting: open, cancelled: counts['cancelled'].to_i },
          mode: run.mode, scheduled_at: run.scheduled_at, batches: Array(run.progress['batches']).size,
          created_at: run.created_at, stopped_at: run.stopped_at }
      end

      # One model's share: drawings not made yet (and not counted for an
      # earlier model in seen), outlines not made yet, and their cost.
      def model_cost(variant, rates, seen, outlined)
        buyer = Buyer.new(nil, variant)
        photos = PhotoChoice.photos(variant)
        return { photos: 0, drawings: 0, recuts: 0, shared: 0, already_drawn: 0, outlines: 0, cost_usd: 0.0, note: 'No photos' } if photos.empty?

        plan = buyer.plan
        return { photos: photos.size, drawings: 0, recuts: 0, shared: 0, already_drawn: 0, outlines: 0, cost_usd: 0.0, note: 'No finishes in the price book' } if plan.empty?

        # Claude has not picked this model's photos yet: the run may draw on
        # others than the first ones, so nothing counts as drawn already.
        unpicked = PhotoChoice.needs_pick?(variant)
        missing = unpicked ? [] : buyer.missing(plan)
        fresh = unpicked ? plan.uniq { |p| [p[:photo], p[:key]] } : missing.reject { |_, old| old }.map(&:first)
        # Drawn under an older cut: cut again on the current outline, paying only for its check.
        recut_ids = missing.select { |_, old| old }.map { |p, _| [p[:photo], p[:key], p[:prompt]] }.reject { |id| seen.include?(id) }
        seen.merge(recut_ids)
        ids = fresh.map { |p| [p[:photo], p[:key], p[:prompt]] }
        shared = ids.count { |id| seen.include?(id) }
        seen.merge(ids)
        surfaces = plan.filter_map { |p| (c = Surfaces.category(p[:selection].first['surface'])) && [p[:photo], c] }.uniq
        have = unpicked ? Set.new : TruebuildSurfaceMask.where(source_url: photos.map(&:last), version: Surfaces::VERSION).pluck(:source_url, :surface).to_set
        new_outlines = surfaces.reject { |s| have.include?(s) || outlined.include?(s) }
        outlined.merge(new_outlines)
        drawings = ids.size - shared
        # Drawings, not options: a color chip and the paid upgrade of the same
        # color are one drawing, and counting options called 26 never-drawn
        # Aspire models "Partly drawn" (four such pairs each).
        all_drawings = plan.map { |p| [p[:photo], p[:key]] }.uniq.size
        open_drawings = unpicked ? all_drawings : missing.map { |p, _| [p[:photo], p[:key]] }.uniq.size
        { photos: photos.size, drawings: drawings, recuts: recut_ids.size, shared: shared, already_drawn: all_drawings - open_drawings,
          outlines: new_outlines.size,
          cost_usd: (drawings * rates[:layer] + new_outlines.size * rates[:outline] + recut_ids.size * RECUT_COST).round(2) }
      end

      # Average cost per drawing and per outline so far, by measurement once
      # there are enough of them.
      def rates(batch: false)
        layers = TruebuildRender.where(purpose: 'layer', model_key: Buyer::MODEL, status: %w[done rejected]).where('cost_usd > 0')
                                .where("usage->>'batch' IS NULL")
        outlines = TruebuildSurfaceMask.where("usage ? 'cost_usd'")
        layer = layers.count >= 50 ? layers.average(:cost_usd).to_f : LAYER_COST
        outline = outlines.count >= 50 ? outlines.average(Arel.sql("(usage->>'cost_usd')::numeric")).to_f : OUTLINE_COST
        layer *= GeminiBatch::DISCOUNT if batch
        { layer: layer.round(4), outline: outline.round(4) }
      end

      def name(variant)
        variant.media.to_h['name'].presence || [variant.catalog_plan&.series, variant.catalog_plan&.name].compact.join(' ')
      end
    end
  end
end
