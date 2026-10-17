# frozen_string_literal: true

require 'vips'

module Truebuild
  module Trueview
    # What is done with a drawing that failed its check before anyone pays
    # for another drawing. Of the 244 drawings two factories held back that
    # were neither refrigerators nor colors with a sample, about 170 had part
    # of the surface left in its old finish. Where the drawing left part of its
    # outline as it was, the change it made on the rest is carried onto the
    # part it skipped (fill).
    #
    # Where it changed nearly all of its outline, the outline itself missed
    # part of the surface. Outlining again was tried on production
    # (2026-10-16): of 57 drawings cut again on 8 new outlines, 6 held ones
    # passed and 8 that had passed failed, for about $4. It is not done.
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

      # => [result, layer, verdict, cost]. The drawing as it was when nothing
      # could be touched or the touched one failed too.
      def settle(source_bytes, result, layer, verdict, mask, check_with, surface:, value:, key: nil, photo: nil)
        as_was = [result, layer, verdict, 0.0]
        return as_was if verdict['ok'] || !mask&.present?

        outline = Trueview.mask_image(mask)
        original = Surfaces.rgb(Vips::Image.new_from_buffer(source_bytes, ''))
        drawn = Layer.fit(Surfaces.rgb(Vips::Image.new_from_buffer(result[:bytes], '')), original.width, original.height)
        inside = Layer.fit(outline.bands > 1 ? outline.extract_band(0) : outline, original.width, original.height) > 127
        still = inside & (delta(original, drawn) <= CHANGED_DE)
        changed = 1.0 - (still.avg / [inside.avg, 1e-6].max)

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
        return [result, layer, verdict, cost] unless again['ok']

        [result.merge(bytes: bytes, mime: 'image/png'), fixed, again.merge('touched' => how, 'touched_hex' => hex).compact, cost]
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
    end
  end
end
