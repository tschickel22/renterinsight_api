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

      VERSION = 2       # 1 was text segmentation; its outlines are not used
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
        ['shingles', /shingle|roof/i, "the main house's roof shingles"],
        ['corner posts', /corner post/i, "the vertical corner trim posts at the corners of the main house"]
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
        url = Trueview.store_bytes(mask.pngsave_buffer(compression: 9), 'image/png',
                                   "truebuild/trueview/masks/#{Digest::SHA256.hexdigest(source_url)[0, 16]}-#{key.parameterize}-v#{VERSION}.png")
        TruebuildSurfaceMask.create!(source_url: source_url, surface: key, version: VERSION, mask_url: url, coverage: coverage,
                                     model: result[:model], usage: result[:usage].merge('cost_usd' => Trueview.cost(spec, result[:usage])))
      rescue Trueview::Error, Vips::Error => e
        TruebuildSurfaceMask.create!(source_url: source_url, surface: key, version: VERSION, status: 'failed', error: e.message.first(500))
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
