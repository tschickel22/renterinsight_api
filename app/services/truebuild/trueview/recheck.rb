# frozen_string_literal: true

module Truebuild
  module Trueview
    # Held-back drawings judged again from the drawing already paid for: a
    # refrigerator under the check that no longer asks for a door layout the
    # photo cannot have, a finish with a factory sample brought to the
    # sample's color (ColorMatch). Nothing is drawn again. Drawings held back
    # for anything else would need a new drawing, which the larger model fixed
    # about one time in four, so they are left as they are.
    module Recheck
      module_function

      PER_ROW = 0.03 # a check, a second look at a 4 and a color-matched check, at most

      # => { checked:, passed:, skipped:, spent_usd: }
      def call(renders, budget_usd:)
        tally = { checked: 0, passed: 0, skipped: 0, spent_usd: 0.0 }
        renders.where(status: 'rejected', purpose: 'layer').where.not(image_url: nil).find_each do |render|
          break if tally[:spent_usd] + PER_ROW > budget_usd

          before = render.cost_usd.to_f
          outcome = one(render)
          tally[outcome] += 1
          render.reload
          tally[:spent_usd] += render.cost_usd.to_f - before
          tally[:passed] += 1 if render.status == 'done'
        rescue StandardError => e
          raise if Credits.error?(e) # out of credits: every row would fail the same way
          Rails.logger.warn("[TrueView] recheck #{render.id}: #{e.message.first(200)}")
          tally[:skipped] += 1
        end
        tally.merge(spent_usd: tally[:spent_usd].round(2))
      end

      def one(render)
        surface = render.selection.first&.dig('surface')
        value = render.selection.first&.dig('value')
        swatch = CatalogSwatch.find_by(id: Array(render.usage['swatch_ids']).first)
        fridge = OptionLook.fridge?(surface, value) && surface.to_s.match?(OptionLook::APPLIANCES)
        return :skipped unless fridge || swatch&.hex.present?

        source = Trueview.fetch_source(render.source_url)
        # Only an outline already made: a missing one would be a paid outlining.
        mask = TruebuildSurfaceMask.find_by(source_url: render.source_url, surface: Surfaces.category(surface), version: Surfaces::VERSION)
        return :skipped unless mask&.present?

        sample = swatch && Trueview.fetch_source(swatch.image_url)[:bytes]
        Trueview.recut!(render, source, mask, { sample: sample, hex: swatch&.hex }, redraw: false)
        :checked
      end
    end
  end
end
