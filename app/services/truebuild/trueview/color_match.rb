# frozen_string_literal: true

require 'vips'

module Truebuild
  module Trueview
    # A drawing whose check found the color off is brought to the sample's
    # color, keeping what the image model drew: the grain, the veining, the
    # light and shade. The surface's typical color is moved to the color a
    # tint would lay there (Tint.paint), one gain per channel, so a Timberwolf
    # drawn a warmer, darker brown becomes Timberwolf without being drawn again.
    #
    # On the first two factories 224 drawings were held back for color alone;
    # a redraw on the larger model fixed about one in four, at about 35 cents
    # for each one fixed. This costs one check and no drawing.
    module ColorMatch
      module_function

      GAIN = (0.33..3.0) # a drawing further off than this is the wrong finish, not the wrong shade

      # => { drawn:, layer:, verdict: } for the corrected drawing, or nil when
      # there is no sample color or outline to correct to.
      def attempt(source_bytes, drawn_bytes, mask, check_with, surface:, value:)
        hex = check_with[:hex]
        return nil unless hex.present? && mask&.present?

        outline = Trueview.mask_image(mask)
        fixed = correct(source_bytes, drawn_bytes, outline, hex) or return nil
        layer = Layer.build(source_bytes, fixed[:bytes], mask: outline, blocked: Trueview.blocked_image(mask, source_bytes))
        verdict = LayerCheck.judge(source_bytes, layer[:bytes], surface: surface, value: value, **check_with)
        { drawn: fixed, layer: layer, verdict: verdict.merge('color_matched' => true) }
      rescue Vips::Error => e
        Rails.logger.warn("[TrueView] color match skipped: #{e.message.first(200)}")
        nil
      end

      # A drawing that failed its check, corrected once if that passes.
      # => [result, layer, verdict, cost of the try]; the drawing as it was
      # when there is nothing to correct or the correction failed too.
      def settle(source_bytes, result, layer, verdict, mask, check_with, surface:, value:)
        return [result, layer, verdict, 0.0] if verdict['ok']

        fixed = attempt(source_bytes, result[:bytes], mask, check_with, surface: surface, value: value)
        return [result, layer, verdict, 0.0] unless fixed

        cost = fixed[:verdict]['cost_usd'].to_f
        return [result, layer, verdict, cost] unless fixed[:verdict]['ok']

        [result.merge(bytes: fixed[:drawn][:bytes], mime: fixed[:drawn][:mime]), fixed[:layer], fixed[:verdict], cost]
      end

      # The drawing with the outlined surface moved to hex. nil when the
      # surface is too small to measure or too far off to correct.
      def correct(source_bytes, drawn_bytes, mask_image, hex, exposure: Tint::EXPOSURE)
        photo = Vips::Image.new_from_buffer(source_bytes, '')
        drawn = Layer.fit(Surfaces.rgb(Vips::Image.new_from_buffer(drawn_bytes, '')), photo.width, photo.height)
        mask = Layer.fit(mask_image.bands > 1 ? mask_image.extract_band(0) : mask_image, photo.width, photo.height) > 127
        linear = drawn.colourspace(:scrgb)
        target = Tint.target_linear(hex).map { |c| c * exposure }
        gains = linear.bandsplit.each_with_index.map do |band, i|
          typical = Tint.median(mask.ifthenelse(band, 0), mask)
          return nil unless typical&.positive?

          gain = target[i] / typical
          return nil unless GAIN.cover?(gain)

          gain
        end
        moved = (linear * gains).cast(:float)
        moved = (moved > 1.0).ifthenelse(1.0, moved).copy(interpretation: :scrgb)
        out = mask.ifthenelse(moved, linear).colourspace(:srgb).cast(:uchar)
        { bytes: out.pngsave_buffer, mime: 'image/png' }
      end
    end
  end
end
