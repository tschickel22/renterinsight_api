# frozen_string_literal: true

require 'vips'

module Truebuild
  module Trueview
    # A drawing whose check found the color off is brought to the finish's
    # color, keeping what the image model drew: the grain, the veining, the
    # light and shade. The surface's typical color is moved to the color a
    # tint would lay there (Tint.paint), one gain per channel, so a Timberwolf
    # drawn a warmer, darker brown becomes Timberwolf without being drawn again.
    #
    # The color is the factory sample's when there is one. When there is not,
    # it is learned from a drawing of the same finish that passed its check on
    # another photo, so Destin White on one kitchen sets Destin White on the next.
    #
    # On the first two factories 224 drawings were held back for color alone;
    # a redraw on the larger model fixed about one in four, at about 35 cents
    # for each one fixed. This costs one check and no drawing (Touchup).
    module ColorMatch
      module_function

      GAIN = (0.33..3.0) # a drawing further off than this is the wrong finish, not the wrong shade
      DONORS = 3         # passed drawings a learned color is averaged over

      # The drawing with the outlined surface moved to hex. nil when the
      # surface is too small to measure or too far off to correct.
      def correct(source_bytes, drawn_bytes, mask_image, hex)
        photo = Vips::Image.new_from_buffer(source_bytes, '')
        drawn = Layer.fit(Surfaces.rgb(Vips::Image.new_from_buffer(drawn_bytes, '')), photo.width, photo.height)
        mask = Layer.fit(mask_image.bands > 1 ? mask_image.extract_band(0) : mask_image, photo.width, photo.height) > 127
        moved = move(drawn, mask, hex) or return nil
        { bytes: moved.pngsave_buffer, mime: 'image/png' }
      end

      # drawn: sRGB image; mask: boolean image the same size. => sRGB image or nil.
      def move(drawn, mask, hex, exposure: Tint::EXPOSURE)
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
        mask.ifthenelse(moved, linear).colourspace(:srgb).cast(:uchar)
      end

      # The finish's color as passed drawings on other photos show it, in the
      # terms of a sample hex (so move lays it as it would a sample's). nil
      # when no other photo has passed it yet.
      def learned_hex(selection_key, photo, surface)
        return nil if selection_key.blank?

        key = Surfaces.category(surface) or return nil
        Rails.cache.fetch("truebuild:colormatch:learned:v1:#{selection_key}:#{photo}", expires_in: 6.hours, skip_nil: true) do
          donors = TruebuildRender.where(selection_key: selection_key, purpose: 'layer', status: 'done')
                                  .where.not(source_url: photo).where.not(image_url: nil).limit(DONORS * 3).to_a
          colors = donors.filter_map { |r| measured(r, key) }.first(DONORS)
          next nil if colors.empty?

          mean = (0..2).map { |i| colors.sum { |c| c[i] } / colors.size }
          to_hex(mean.map { |c| c / Tint::EXPOSURE })
        end
      end

      # A passed drawing's typical linear color inside its outline, or nil.
      def measured(render, key)
        mask_row = TruebuildSurfaceMask.find_by(source_url: render.source_url, surface: key, version: Surfaces::VERSION)
        return nil unless mask_row&.present?

        drawn = Surfaces.rgb(Vips::Image.new_from_buffer(Trueview.fetch_source(render.image_url)[:bytes], ''))
        mask = Trueview.mask_image(mask_row)
        mask = Layer.fit(mask.bands > 1 ? mask.extract_band(0) : mask, drawn.width, drawn.height) > 127
        linear = drawn.colourspace(:scrgb)
        values = linear.bandsplit.map { |band| Tint.median(mask.ifthenelse(band, 0), mask) }
        values.all? { |v| v&.positive? } ? values : nil
      rescue StandardError => e
        Rails.logger.warn("[TrueView] learned color from #{render.id}: #{e.message.first(160)}")
        nil
      end

      def to_hex(linear)
        '#' + linear.map do |c|
          c = c.clamp(0.0, 1.0)
          s = c <= 0.0031308 ? c * 12.92 : (1.055 * (c**(1 / 2.4))) - 0.055
          format('%02x', (s * 255).round.clamp(0, 255))
        end.join
      end
    end
  end
end
