# frozen_string_literal: true

require 'vips'

module Truebuild
  module Trueview
    # Finds each surface in the original photo, once, and a layer is then
    # the drawing inside that outline only.
    #
    # Cutting by what the drawing changed kept everything the model touched
    # along the way: bar stools it removed, lawn and floor it redrew, so
    # layers bled and stacked layers seamed. The outline is the same for
    # every color of a surface, and a surface the photo does not show gets
    # no layer at all.
    #
    # The outline is found by having the image model paint the surface pure
    # magenta and keeping the magenta pixels: recoloring a named surface is
    # what it does best. Gemini's text segmentation was tried first; the
    # model Google now offers for it answered with garbled text and empty
    # outlines, which hid real surfaces.
    module Surfaces
      module_function

      VERSION = 4       # 1 text segmentation, 2 unchecked, 3 checked against a filled overlay
      PAINTER = 'nb2-lite'
      MAGENTA = [255, 0, 255]
      MAGENTA_DE = 45   # CIE dE76 from pure magenta that still counts as painted
      RETRY_FAILED_AFTER = 30.minutes
      MIN_PRESENT = 0.003 # share of the photo; less is not really in it

      # [key, matches a finish's surface name, what to outline]
      CATEGORIES = [
        ['cabinets', /cabinet|vanit|lav|hw /i,
         'the cabinet doors, drawer fronts and cabinet boxes, including an island base and any vanity. Not countertops, appliances, sinks, stools, chairs or the floor'],
        ['countertop', /counter/i, 'the countertops, including an island top and any short backsplash lip of the same material. Not the sink'],
        ['backsplash', /backsplash/i, 'the backsplash: the wall surface between the countertop and the upper cabinets'],
        ['flooring', /floor|carpet/i, 'the floor. Not rugs, furniture legs or cabinets'],
        ['accent wall', /accent|wall ?board/i, 'the single largest interior wall facing the camera'],
        ['siding', /siding|shake/i, "the main house's exterior wall siding. Not trim, windows, doors, roof, skirting, porch or neighboring houses"],
        ['shutters', /shutter/i, 'the window shutters on the main house'],
        ['shingles', /shingle|roof/i,
         "the sloped roof surfaces of the main house covered in shingles. Not the siding or shakes in the gable triangle, not the trim or gutters"],
        ['corner posts', /corner post/i,
         "the narrow vertical trim boards at the outside corners of the main house's walls. Not porch posts, columns or downspouts"]
      ].freeze

      def category(surface)
        CATEGORIES.find { |_, re, _| surface.to_s.match?(re) }&.first
      end

      # The mask record for a photo and surface, finding it on first use.
      # nil for a surface no category covers (the layer falls back to the
      # change-based cut).
      def mask_for(source_url, source_bytes, surface)
        key = category(surface) or return nil
        found = TruebuildSurfaceMask.find_by(source_url: source_url, surface: key, version: VERSION)
        return found if found && (found.status == 'done' || found.updated_at > RETRY_FAILED_AFTER.ago)

        found&.destroy!
        find!(source_url, source_bytes, key)
      rescue ActiveRecord::RecordNotUnique
        TruebuildSurfaceMask.find_by(source_url: source_url, surface: key, version: VERSION)
      end

      def find!(source_url, source_bytes, key)
        description = CATEGORIES.find { |k, _, _| k == key }.last
        image = rgb(Vips::Image.new_from_buffer(source_bytes, ''))
        spec = MODELS.fetch(PAINTER)
        result = Providers::Gemini.edit(spec, { bytes: source_bytes, mime: 'image/jpeg' }, paint_prompt(description),
                                        aspect: image.width.to_f / image.height)
        if Trueview.reframed_by(result, image.width.to_f / image.height) > Trueview::FRAMING_TOLERANCE
          raise Trueview::Error, 'The model changed the framing while outlining'
        end

        mask = magenta(Vips::Image.new_from_buffer(result[:bytes], ''), image.width, image.height)
        coverage = (mask.avg / 255.0).round(4)
        verdict = coverage.positive? ? check(image, mask, key, description) : { 'right' => true, 'present' => false }
        # A wrong outline would paint the wrong thing in every color: no
        # layer for that surface is better. An absent surface is no layer too.
        coverage = 0 unless verdict['right'] && verdict['present']
        url = Trueview.store_bytes(mask.pngsave_buffer(compression: 9), 'image/png',
                                   "truebuild/trueview/masks/#{Digest::SHA256.hexdigest(source_url)[0, 16]}-#{key.parameterize}-v#{VERSION}.png")
        TruebuildSurfaceMask.create!(source_url: source_url, surface: key, version: VERSION, mask_url: url, coverage: coverage,
                                     model: result[:model], error: verdict['note'].presence,
                                     usage: result[:usage].merge('cost_usd' => Trueview.cost(spec, result[:usage]),
                                                                 'check' => verdict.except('note')))
      rescue Trueview::Error, Vips::Error, Catalog::PriceBooks::ClaudeClient::Error => e
        TruebuildSurfaceMask.create!(source_url: source_url, surface: key, version: VERSION, status: 'failed', error: e.message.first(500))
      end

      CHECK_TOOL = {
        name: 'judge_outline',
        description: 'Judge whether the magenta area is exactly the named surface.',
        input_schema: {
          type: 'object',
          properties: {
            present: { type: 'boolean', description: 'Looking ONLY at the first image (the untouched photo): it really shows this surface.' },
            right: { type: 'boolean', description: 'The magenta covers this surface and essentially nothing else.' },
            note: { type: 'string', description: 'One short sentence: what is wrong, if anything.' }
          },
          required: %w[present right]
        }
      }.freeze

      # Claude looks at the photo and the outline over it and says whether
      # the outline is the surface, and whether the photo shows it at all.
      # Asked for shutters on a house with none, Lite painted shutter-shaped
      # strips beside the windows; filled in magenta they looked like
      # shutters and passed. So presence is judged on the untouched photo,
      # and the outline is drawn as a border over a light tint, leaving what
      # is really inside it visible.
      def check(image, mask, key, description)
        look = ->(img) { Base64.strict_encode64(img.thumbnail_image(1000).jpegsave_buffer(Q: 80)) }
        inside = mask > 127
        edge = inside.morph(Layer.disc(3), :dilate) ^ inside.morph(Layer.disc(3), :erode)
        tinted = inside.ifthenelse((image * 0.8 + [51, 0, 51]).cast(:uchar), image)
        tinted = edge.ifthenelse([255, 0, 255], tinted).cast(:uchar).copy(interpretation: :srgb)
        result = Catalog::PriceBooks::ClaudeClient.call(
          system: 'You check outlines of home surfaces for a home configurator. Be strict: an outline that also covers ' \
                  'other things (windows, posts, walls, floor, furniture) is wrong.',
          tool: CHECK_TOOL, max_tokens: 400, temperature: 0,
          content: [{ type: 'text', text: 'Photo:' }, { type: 'image', source: { type: 'base64', media_type: 'image/jpeg', data: look.(image) } },
                    { type: 'text', text: "First, from that photo alone: does it show #{key}? Then the same photo with an " \
                                          "outline drawn as a magenta border with a light tint inside. It should be #{key}: " \
                                          "#{description}. Judge what is really inside the border." },
                    { type: 'image', source: { type: 'base64', media_type: 'image/jpeg', data: look.(tinted) } }]
        )
        result[:input].slice('present', 'right', 'note')
                      .merge('cost_usd' => Catalog::PriceBooks::ClaudeClient.cost_usd(result[:input_tokens], result[:output_tokens]).round(4))
      end

      def paint_prompt(description)
        <<~TEXT.strip
          This is a real photograph. Paint #{description} solid, flat, pure magenta (#FF00FF): no shading, texture or
          reflections on it. Change nothing else at all: every other pixel, the framing, the camera and the objects in
          front of it stay exactly as they are. If the photo does not show any, return the photo unchanged.
        TEXT
      end

      # The painted pixels, cleaned of specks and pinholes, at the photo's size.
      def magenta(painted, width, height)
        painted = Layer.fit(rgb(painted), width, height)
        target = painted.new_from_image(MAGENTA).cast(:uchar).copy(interpretation: :srgb)
        delta = painted.colourspace(:lab).dE76(target.colourspace(:lab))
        mask = (delta < MAGENTA_DE).ifthenelse(255, 0).cast(:uchar)
        mask.median(5).morph(Layer.disc(2), :dilate).morph(Layer.disc(2), :erode)
      end

      def rgb(image)
        image = image.colourspace(:srgb) unless image.interpretation == :srgb
        image.bands > 3 ? image.extract_band(0, n: 3) : image
      end
    end
  end
end
