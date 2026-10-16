# frozen_string_literal: true

require 'vips'

module Truebuild
  module Trueview
    # What is done with a drawing that failed its check before anyone pays
    # for another drawing. Of the 244 drawings two factories held back that
    # were neither refrigerators nor colors with a sample, about 170 had part
    # of the surface left in its old finish, and those came in two kinds:
    #
    # - The drawing changed nearly all of its outline: the outline itself
    #   missed part of the surface (the cabinets beside a refrigerator, a
    #   crown molding). No drawing can fix that, so the surface is outlined
    #   again, once, told what was missed, and every color of it on the photo
    #   is cut again (Surfaces.redo!).
    # - The drawing left part of its outline as it was: the change it made on
    #   the rest is carried onto the part it skipped (fill).
    #
    # Then, where the finish's color is known (ColorMatch), the surface is
    # moved to it. The touched drawing gets one check; nothing is drawn again.
    module Touchup
      module_function

      CHANGED_DE = 6      # a pixel the drawing changed, as the cut measures (Layer)
      PAINTED = 0.95      # share of the outline changed above which the drawing did its part
      LEARN_FROM = 0.2    # share changed below which there is too little to carry onto the rest
      # A fill carries a whole change of finish (grey to dark wood is a linear
      # gain near 0.05), not a correction of shade, so it may go far; past
      # this the photo's pixel is near black and holds no light to carry.
      FILL_GAIN = (0.01..60.0)
      LEFT_OLD = /\b(old|original|unchanged|retain|retains|retained|still|remains?|untouched|not (been )?(changed|repainted|recolou?red))\b/i

      # => [result, layer, verdict, cost, outline_redone]. The drawing as it
      # was when nothing could be touched or the touched one failed too.
      def settle(source_bytes, result, layer, verdict, mask, check_with, surface:, value:, key: nil, photo: nil)
        as_was = [result, layer, verdict, 0.0, false]
        return as_was if verdict['ok'] || !mask&.present?

        outline = Trueview.mask_image(mask)
        original = Surfaces.rgb(Vips::Image.new_from_buffer(source_bytes, ''))
        drawn = Layer.fit(Surfaces.rgb(Vips::Image.new_from_buffer(result[:bytes], '')), original.width, original.height)
        inside = Layer.fit(outline.bands > 1 ? outline.extract_band(0) : outline, original.width, original.height) > 127
        still = inside & (delta(original, drawn) <= CHANGED_DE)
        changed = 1.0 - (still.avg / [inside.avg, 1e-6].max)

        if changed >= PAINTED && verdict['note'].to_s.match?(LEFT_OLD)
          return [result, layer, verdict, 0.0, redo_outline!(mask, verdict['note'])]
        end

        touched = drawn
        how = []
        if changed < PAINTED && changed >= LEARN_FROM && (filled = fill(original, drawn, inside, still))
          touched = filled
          how << 'filled'
        end
        hex = check_with[:hex].presence || ColorMatch.learned_hex(key, photo, surface)
        if hex && (moved = ColorMatch.move(touched, inside, hex))
          touched = moved
          how << (check_with[:hex].present? ? 'color_matched' : 'color_learned')
        end
        return as_was if how.empty?

        bytes = touched.pngsave_buffer
        fixed = Layer.build(source_bytes, bytes, mask: outline, blocked: Trueview.blocked_image(mask, source_bytes))
        again = LayerCheck.judge(source_bytes, fixed[:bytes], surface: surface, value: value, **check_with)
        cost = again['cost_usd'].to_f
        return [result, layer, verdict, cost, false] unless again['ok']

        [result.merge(bytes: bytes, mime: 'image/png'), fixed, again.merge('touched' => how, 'touched_hex' => hex).compact, cost, false]
      rescue Vips::Error => e
        Rails.logger.warn("[TrueView] touch-up skipped: #{e.message.first(200)}")
        as_was
      end

      def delta(original, drawn)
        original.gaussblur(1.5).colourspace(:lab).dE76(drawn.gaussblur(1.5).colourspace(:lab))
      end

      # The skipped part of the outline given the change the drawing made on
      # the rest: per channel, the typical ratio of drawn to photo where it
      # did change, applied to the photo where it did not.
      def fill(original, drawn, inside, still)
        changed = inside & ~still
        photo = original.colourspace(:scrgb)
        linear = drawn.colourspace(:scrgb)
        gains = photo.bandsplit.zip(linear.bandsplit).map do |was, now|
          before = Tint.median(changed.ifthenelse(was, 0), changed)
          after = Tint.median(changed.ifthenelse(now, 0), changed)
          return nil unless before&.positive? && after&.positive?

          gain = after / before
          return nil unless FILL_GAIN.cover?(gain)

          gain
        end
        carried = (photo * gains).cast(:float)
        carried = (carried > 1.0).ifthenelse(1.0, carried).copy(interpretation: :scrgb)
        still.ifthenelse(carried, linear).colourspace(:srgb).cast(:uchar)
      end

      # Outlined again in the background, once per outline for this reason.
      # => true when asked for.
      def redo_outline!(mask, note)
        return false if mask.usage['coverage_redo'] || mask.usage['redo_pending']

        mask.update_columns(usage: mask.usage.merge('coverage_redo' => true, 'redo_pending' => true), updated_at: Time.current)
        TruebuildOutlineRedoJob.perform_later(mask.id, "The outline left out part of the #{mask.surface} that a check found " \
                                                       "in its old finish: #{note} Cover all of the #{mask.surface}.")
        true
      end
    end
  end
end
