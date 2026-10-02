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
      def estimate(variants)
        rates = self.rates
        seen = Set.new
        outlined = Set.new
        models = variants.map do |v|
          cost = model_cost(v, rates, seen, outlined)
          { id: v.id, name: name(v), model_number: v.model_number, series: v.catalog_plan&.series }.merge(cost)
        end
        drawings = models.sum { |m| m[:drawings] }
        outlines = models.sum { |m| m[:outlines] }
        { models: models,
          totals: { models: models.size, with_photos: models.count { |m| m[:photos].positive? },
                    drawings: drawings, shared: models.sum { |m| m[:shared] }, already_drawn: models.sum { |m| m[:already_drawn] },
                    outlines: outlines, cost_usd: (drawings * rates[:layer] + outlines * rates[:outline]).round(2) },
          rates: rates }
      end

      def start!(variants, budget_usd:, scope:, by: nil)
        run = TruebuildFactoryRun.create!(manufacturer_id: scope[:manufacturer_id], factory_id: scope[:factory_id].presence,
                                          series: scope[:series].presence, budget_usd: budget_usd, created_by_id: by&.id,
                                          variant_ids: variants.map(&:id), estimate: estimate(variants)[:totals])
        TruebuildFactoryRunJob.perform_later(run.id)
        run
      end

      # Model by model: Claude picks its photos if nobody has, then every
      # missing drawing is queued. Stops before a model that would go over
      # budget, and when stopped.
      def queue!(run)
        rates = self.rates
        # Outlines are made as drawings run, so a later model with the same
        # photo must not be charged for one an earlier model has queued.
        seen = Set.new
        outlined = Set.new
        run.variant_ids.each_with_index do |id, i|
          next if i < run.models_queued

          return unless run.reload.status == 'running'

          variant = CatalogPlanVariant.find_by(id: id)
          committed = run.committed_usd
          if variant && Array(variant.shown_media['photos']).any?
            PhotoChoice.pick!(variant) if PhotoChoice.needs_pick?(variant)
            variant.reload
            cost = model_cost(variant, rates, seen, outlined)
            if committed + cost[:cost_usd] > run.budget_usd.to_f
              run.update!(status: 'budget_reached')
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
          return if round >= REPAIR_ROUNDS || run.progress['repair_queued'].to_i > round

          run.update!(progress: run.progress.merge('repair_queued' => round + 1))
        end
        TruebuildFactoryRunRepairJob.perform_later(run.id)
      end

      # One round. Returns the number of drawings queued again.
      def repair!(run)
        round = run.progress['repair_rounds'].to_i + 1
        rates = self.rates
        spent = run.renders.sum(:cost_usd).to_f + run.progress['outline_repair_usd'].to_f
        variants = CatalogPlanVariant.where(id: run.variant_ids).to_a
        photos = variants.flat_map { |v| PhotoChoice.photos(v).map(&:last) }.uniq

        outline_usd = 0.0
        failed_outlines(photos).each do |mask|
          break if spent + outline_usd + rates[:outline] > run.budget_usd.to_f

          source = Trueview.fetch_source(mask.source_url)
          note = mask.error
          mask.destroy!
          fresh = Surfaces.find!(mask.source_url, source[:bytes], mask.surface, correction: note)
          outline_usd += fresh.usage['cost_usd'].to_f
          # Drawings skipped as "not in this photo" for want of an outline are drawn now.
          if fresh.present?
            TruebuildRender.where(source_url: mask.source_url, purpose: 'layer', status: 'skipped').to_a
                           .select { |r| Surfaces.category(r.selection.first&.dig('surface')) == mask.surface }
                           .each { |r| r.update!(status: 'superseded') }
          end
        rescue StandardError => e
          Rails.logger.warn("TrueView repair outline #{mask.id}: #{e.message}")
        end
        spent += outline_usd

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
          TruebuildRenderJob.set(queue: :low, priority: PRIORITY).perform_later(row.id)
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
                                                 'outline_repair_usd' => (run.progress['outline_repair_usd'].to_f + outline_usd).round(4),
                                                 'repaired' => run.progress['repaired'].to_i + queued))
        queued
      end

      # Outlines worth another try: one that errored (not on framing, which
      # fails the same way again), and one Claude found the surface in but
      # rejected the outline of. That one is stored as no outline, so every
      # color of the surface was skipped as not in the photo.
      def failed_outlines(photos)
        TruebuildSurfaceMask.where(source_url: photos, version: Surfaces::VERSION).select do |m|
          if m.status == 'failed' then !m.error.to_s.include?('framing')
          else m.status == 'done' && m.coverage.to_f.zero? && Array(m.usage['attempts']).last.to_h['present'] == true
          end
        end
      end

      # Every note the checks and reviewers have made on this photo and
      # finish, so a new drawing is told all of what went wrong, not just the last.
      def notes(render)
        [render.usage['reviewer_note'], render.usage.dig('check', 'note')].compact_blank.uniq.join(' Also: ')
      end

      # Where a run stands, from its drawings.
      def progress(run)
        counts = run.renders.group(:status).count
        open = counts.values_at('queued', 'running').compact.sum
        repair_queued = run.progress['repair_queued'].to_i
        phase = if run.status != 'running' then run.status
                elsif run.models_queued < run.variant_ids.size then 'queuing'
                elsif open.positive? then repair_queued.positive? ? 'repairing' : 'drawing'
                elsif repair_queued > run.progress['repair_rounds'].to_i then 'repairing'
                else 'finished'
                end
        { id: run.id, phase: phase, manufacturer: run.manufacturer&.name, factory_id: run.factory_id, series: run.series,
          budget_usd: run.budget_usd.to_f, committed_usd: run.committed_usd, spent_usd: (run.renders.sum(:cost_usd).to_f + run.progress['outline_repair_usd'].to_f).round(2),
          models: run.variant_ids.size, models_queued: run.models_queued, estimate: run.estimate,
          repair: { rounds: run.progress['repair_rounds'].to_i, redrawn: run.progress['repaired'].to_i },
          drawings: { done: counts['done'].to_i, held_back: counts['rejected'].to_i, not_in_photo: counts['skipped'].to_i,
                      failed: counts['failed'].to_i, waiting: open, cancelled: counts['cancelled'].to_i },
          created_at: run.created_at, stopped_at: run.stopped_at }
      end

      # One model's share: drawings not made yet (and not counted for an
      # earlier model in seen), outlines not made yet, and their cost.
      def model_cost(variant, rates, seen, outlined)
        buyer = Buyer.new(nil, variant)
        photos = PhotoChoice.photos(variant)
        return { photos: 0, drawings: 0, shared: 0, already_drawn: 0, outlines: 0, cost_usd: 0.0, note: 'No photos' } if photos.empty?

        plan = buyer.plan
        return { photos: photos.size, drawings: 0, shared: 0, already_drawn: 0, outlines: 0, cost_usd: 0.0, note: 'No finishes in the price book' } if plan.empty?

        # Claude has not picked this model's photos yet: the run may draw on
        # others than the first ones, so nothing counts as drawn already.
        unpicked = PhotoChoice.needs_pick?(variant)
        fresh = unpicked ? plan.uniq { |p| [p[:photo], p[:key]] } : buyer.missing(plan).reject { |_, old| old }.map(&:first) # an older cut is cut again for free
        ids = fresh.map { |p| [p[:photo], p[:key], p[:prompt]] }
        shared = ids.count { |id| seen.include?(id) }
        seen.merge(ids)
        surfaces = plan.filter_map { |p| (c = Surfaces.category(p[:selection].first['surface'])) && [p[:photo], c] }.uniq
        have = unpicked ? Set.new : TruebuildSurfaceMask.where(source_url: photos.map(&:last), version: Surfaces::VERSION).pluck(:source_url, :surface).to_set
        new_outlines = surfaces.reject { |s| have.include?(s) || outlined.include?(s) }
        outlined.merge(new_outlines)
        drawings = ids.size - shared
        { photos: photos.size, drawings: drawings, shared: shared, already_drawn: plan.size - fresh.size, outlines: new_outlines.size,
          cost_usd: (drawings * rates[:layer] + new_outlines.size * rates[:outline]).round(2) }
      end

      # Average cost per drawing and per outline so far, by measurement once
      # there are enough of them.
      def rates
        layers = TruebuildRender.where(purpose: 'layer', model_key: Buyer::MODEL, status: %w[done rejected]).where('cost_usd > 0')
        outlines = TruebuildSurfaceMask.where("usage ? 'cost_usd'")
        layer = layers.count >= 50 ? layers.average(:cost_usd).to_f : LAYER_COST
        outline = outlines.count >= 50 ? outlines.average(Arel.sql("(usage->>'cost_usd')::numeric")).to_f : OUTLINE_COST
        { layer: layer.round(4), outline: outline.round(4) }
      end

      def name(variant)
        variant.media.to_h['name'].presence || [variant.catalog_plan&.series, variant.catalog_plan&.name].compact.join(' ')
      end
    end
  end
end
