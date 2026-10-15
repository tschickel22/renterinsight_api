# frozen_string_literal: true

require 'vips'

module Truebuild
  module Trueview
    # A plain color laid on the photo itself, with no image model: the
    # surface's outline (Surfaces) is filled with the factory sample's color,
    # carrying the photo's own light and shade, siding laps and panel lines.
    # About half a factory run's drawings are plain colors (siding, shutters,
    # an accent wall, painted cabinets), and they are where the image model
    # most often missed the shade, so its drawing was held back.
    #
    # Only where the color is known from the factory's sample, never guessed
    # from a name, and only where that sample is flat: a wood grain or a
    # marble is a texture and is still drawn. A tint is checked like a
    # drawing; one that fails its check is drawn instead (Trueview.perform!,
    # Batch.submit!). Off until the platform setting trueview_tint is on.
    module Tint
      module_function

      SURFACES = ['siding', 'shutters', 'accent wall', 'corner posts', 'cabinets', 'shingles'].freeze
      SETTING = 'trueview_tint'
      CHECK_COST = 0.012 # what a tint costs: its check (FactoryRun::RECUT_COST measured the same)
      # Fine detail (grain, print) in the middle of the sample above which it
      # is a texture, per surface whose finishes can be either. Measured on
      # production's 66 samples: painted doors 0.0 to 0.6, Urban Oak 1.07,
      # Chai Oak 1.99; plain wall boards to 1.0, printed ones 2.3 to 6.9.
      # Siding, shutters and shingles are the same product in another color,
      # so their samples (photographs with some noise) are not measured.
      TEXTURE_ABOVE = { 'cabinets' => 0.8, 'accent wall' => 1.5 }.freeze
      SHAKE = /\bshakes?\b/i # cedar shake is a texture, not a lap siding color ("Shaker" cabinets are not)
      SHADE = (0.15..2.6) # how far the photo's light and shade may scale the color, so noise in a dark photo is not blown up

      def enabled? = ActiveModel::Type::Boolean.new.cast(Setting.get('platform', nil, SETTING, false))

      # The color to lay, or nil when this drawing must be drawn: not a plain
      # color surface, no factory sample, or a sample that is a texture.
      def color_for(render)
        return nil unless enabled? && render.purpose == 'layer'
        return nil if render.usage['tint_failed'] # its tint failed the check: drawn instead

        hex_for(render.selection, Array(render.usage['swatch_ids']).first)
      end

      # selection: one finish; swatch_id: its factory sample.
      def hex_for(selection, swatch_id)
        return nil unless selection.size == 1 && swatch_id

        surface = selection.first['surface']
        category = Surfaces.category(surface)
        return nil unless SURFACES.include?(category)

        swatch = CatalogSwatch.find_by(id: swatch_id)
        return nil unless swatch&.hex.present?
        return nil if [surface, selection.first['value'], swatch.set_name].join(' ').match?(SHAKE)
        return nil if TEXTURE_ABOVE[category] && detail(swatch) > TEXTURE_ABOVE[category]

        swatch.hex
      end

      # A sample's fine detail, measured once per sample image.
      def detail(swatch)
        Rails.cache.fetch("truebuild:tint:detail:v1:#{swatch.id}:#{swatch.updated_at.to_i}", expires_in: 30.days) do
          detail_of(Vips::Image.new_from_buffer(Trueview.fetch_source(swatch.image_url)[:bytes], ''))
        end
      end

      # Mean fine detail (lightness against its own blur) in the middle of
      # the sample, away from a door's frame and the sheet's border: a wood
      # grain or a print counts, a painted panel's shading does not.
      def detail_of(img)
        img = Surfaces.rgb(img)
        img = img.resize(300.0 / img.width)
        x = (img.width * 0.3).round
        y = (img.height * 0.3).round
        middle = img.crop(x, y, img.width - 2 * x, img.height - 2 * y).colourspace(:lab).extract_band(0)
        (middle - middle.gaussblur(3)).abs.avg.round(2)
      end

      # The photo with the outlined surface in the new color. Light and shade
      # come from the photo: each pixel keeps its brightness relative to the
      # surface's typical brightness, so the color sits where the photo was
      # lit as the sample, darker in shadow and lighter in the sun.
      def paint(source_bytes, mask_image, hex)
        photo = Surfaces.rgb(Vips::Image.new_from_buffer(source_bytes, ''))
        mask = Layer.fit(mask_image.bands > 1 ? mask_image.extract_band(0) : mask_image, photo.width, photo.height) > 127
        linear = photo.colourspace(:scrgb)
        light = luminance(linear)
        inside = mask.ifthenelse(light, 0)
        typical = median(inside, mask)
        return nil unless typical&.positive?

        shade = (light / typical).cast(:float)
        shade = (shade < SHADE.min).ifthenelse(SHADE.min, shade)
        shade = (shade > SHADE.max).ifthenelse(SHADE.max, shade)
        target = target_linear(hex)
        painted = Vips::Image.bandjoin(target.map { |c| shade * c })
        painted = (painted > 1.0).ifthenelse(1.0, painted).copy(interpretation: :scrgb)
        out = mask.ifthenelse(painted, linear).colourspace(:srgb).cast(:uchar)
        { bytes: out.pngsave_buffer, mime: 'image/png' }
      end

      # Lays the color, cuts and checks it. => true when it passed and the row
      # is done; false when it failed or could not be laid, so the row is to
      # be drawn as usual (marked so it is not tinted again).
      def apply!(render, ctx, hex)
        return false unless ctx[:mask]&.present?

        tinted = paint(ctx[:source][:bytes], Trueview.mask_image(ctx[:mask]), hex) or return false
        layer = Layer.build(ctx[:source][:bytes], tinted[:bytes], mask: Trueview.mask_image(ctx[:mask]),
                                                                  blocked: Trueview.blocked_image(ctx[:mask], ctx[:source][:bytes]))
        verdict = LayerCheck.judge(ctx[:source][:bytes], layer[:bytes], surface: render.selection.first['surface'],
                                                                         value: render.selection.first['value'], **ctx[:check_with])
        spent = render.cost_usd.to_f + verdict['cost_usd'].to_f
        unless verdict['ok']
          render.update!(cost_usd: spent.round(4), usage: render.usage.merge('tint_failed' => true, 'tint_note' => verdict['note']).compact)
          return false
        end

        render.update!(status: 'done', image_url: Trueview.store(render, tinted[:bytes], tinted[:mime], suffix: 'tint'),
                       layer_url: Trueview.store(render, layer[:bytes], layer[:mime], suffix: 'tint-layer'),
                       mask_coverage: layer[:coverage], cost_usd: spent.round(4), latency_ms: 0, model: 'tint',
                       usage: render.usage.merge('tinted' => true, 'tint_hex' => hex, 'mask_version' => Layer::VERSION,
                                                 'check' => verdict.except('cost_usd'), 'outlined' => true))
        true
      end

      def luminance(linear)
        r, g, b = linear.bandsplit
        (r * 0.2126) + (g * 0.7152) + (b * 0.0722)
      end

      # Median brightness of the surface, from its histogram.
      def median(inside, mask)
        count = (mask.cast(:uchar) / 255).avg * mask.width * mask.height
        return nil if count < 50

        scaled = (inside * 1000).cast(:ushort)
        hist = scaled.hist_find.hist_cum
        half = (count / 2.0) + ((mask.width * mask.height) - count) # the zeros outside the mask come first
        (0...hist.width).bsearch { |i| hist.getpoint(i, 0).first >= half }.to_f / 1000
      end

      def target_linear(hex)
        rgb = hex.delete('#').scan(/../).map { |h| h.to_i(16) / 255.0 }
        rgb.map { |c| c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055)**2.4 }
      end
    end
  end
end
