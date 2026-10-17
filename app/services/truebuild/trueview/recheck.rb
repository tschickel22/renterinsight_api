# frozen_string_literal: true

module Truebuild
  module Trueview
    # Held-back drawings worked again from the drawing already paid for,
    # nothing drawn again. A refrigerator is judged again under the check that
    # takes French door and side-by-side for each other. Everything else goes
    # through Touchup with the verdict it already has: a part the drawing
    # skipped is filled, a known color is matched, and the result gets one check.
    module Recheck
      module_function

      PER_ROW = 0.03 # a check, a second look at a 4 and a touched-up check, at most

      # => { 'checked', 'passed', 'nothing_to_touch', 'skipped', 'spent_usd' }
      def call(renders, budget_usd:)
        tally = Hash.new(0)
        spent = 0.0
        renders.where(status: 'rejected', purpose: 'layer').where.not(image_url: nil).find_each do |render|
          break if spent + PER_ROW > budget_usd

          before = render.cost_usd.to_f
          tally[one(render)] += 1
          render.reload
          spent += render.cost_usd.to_f - before
          tally['passed'] += 1 if render.status == 'done'
        rescue StandardError => e
          raise if Credits.error?(e) # out of credits: every row would fail the same way

          Rails.logger.warn("[TrueView] recheck #{render.id}: #{e.message.first(200)}")
          tally['skipped'] += 1
        end
        tally.merge('spent_usd' => spent.round(2))
      end

      def one(render)
        surface = render.selection.first&.dig('surface')
        value = render.selection.first&.dig('value')
        # Only an outline already made: a missing one would be a paid outlining.
        mask = TruebuildSurfaceMask.find_by(source_url: render.source_url, surface: Surfaces.category(surface), version: Surfaces::VERSION)
        return 'skipped' unless mask&.present?

        swatch = CatalogSwatch.find_by(id: Array(render.usage['swatch_ids']).first)
        check_with = { sample: swatch && Trueview.fetch_source(swatch.image_url)[:bytes], hex: swatch&.hex }
        source = Trueview.fetch_source(render.source_url)
        if OptionLook.fridge?(surface, value) && surface.to_s.match?(OptionLook::APPLIANCES)
          Trueview.recut!(render, source, mask, check_with, redraw: false)
          return 'checked'
        end

        touch!(render, source, mask, check_with, surface, value)
      end

      def touch!(render, source, mask, check_with, surface, value)
        verdict = render.usage['check'].to_h.merge('ok' => false)
        verdict['note'] ||= render.error.to_s.delete_prefix('Hidden: ')
        drawn = Trueview.fetch_source(render.image_url)
        drawn, layer, verdict, cost = Touchup.settle(source[:bytes], drawn, nil, verdict, mask, check_with,
                                                     surface: surface, value: value,
                                                     key: render.selection_key, photo: render.source_url)

        attrs = { cost_usd: (render.cost_usd.to_f + cost).round(4) }
        if verdict['ok']
          attrs.merge!(status: 'done', error: nil, mask_coverage: layer[:coverage],
                       image_url: Trueview.store(render, drawn[:bytes], drawn[:mime], suffix: 'touched'),
                       layer_url: Trueview.store(render, layer[:bytes], layer[:mime], suffix: 'touched-layer'),
                       usage: render.usage.merge('check' => verdict.except('cost_usd'), 'mask_version' => Layer::VERSION))
        end
        render.update!(attrs)
        cost.positive? ? 'checked' : 'nothing_to_touch'
      end
    end
  end
end
