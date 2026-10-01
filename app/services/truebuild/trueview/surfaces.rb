# frozen_string_literal: true

require 'vips'

module Truebuild
  module Trueview
    # Finds each surface in the original photo, once, with Gemini's
    # segmentation. A layer is then the drawing inside that outline only.
    #
    # Cutting by what the drawing changed kept everything the model touched
    # along the way: bar stools it removed, lawn and floor it redrew, so
    # layers bled and stacked layers seamed. The outline comes from the
    # untouched photo, is the same for every color of a surface, and leaves
    # whatever stands in front of the surface (a stool before the island) as
    # it is. A surface the photo does not show gets no layer at all.
    module Surfaces
      module_function

      VERSION = 1
      MODEL = 'gemini-2.5-flash'
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
        TruebuildSurfaceMask.find_by(source_url: source_url, surface: key, version: VERSION) || find!(source_url, source_bytes, key)
      rescue ActiveRecord::RecordNotUnique
        TruebuildSurfaceMask.find_by(source_url: source_url, surface: key, version: VERSION)
      end

      def find!(source_url, source_bytes, key)
        description = CATEGORIES.find { |k, _, _| k == key }.last
        image = rgb(Vips::Image.new_from_buffer(source_bytes, ''))
        result = Providers::Gemini.segment({ bytes: source_bytes, mime: 'image/jpeg' }, description, model: MODEL)
        mask = paint(result[:masks], image.width, image.height)
        coverage = (mask.avg / 255.0).round(4)
        url = Trueview.store_bytes(mask.pngsave_buffer(compression: 9), 'image/png',
                                   "truebuild/trueview/masks/#{Digest::SHA256.hexdigest(source_url)[0, 16]}-#{key.parameterize}-v#{VERSION}.png")
        TruebuildSurfaceMask.create!(source_url: source_url, surface: key, version: VERSION, mask_url: url, coverage: coverage,
                                     model: result[:model], usage: result[:usage])
      rescue Trueview::Error, Vips::Error, JSON::ParserError => e
        TruebuildSurfaceMask.create!(source_url: source_url, surface: key, version: VERSION, status: 'failed', error: e.message.first(500))
      end

      # Gemini answers with boxes on a 0..1000 grid and a probability map for
      # each box; together they make one full-size 0/255 mask.
      def paint(masks, width, height)
        canvas = Vips::Image.black(width, height).cast(:uchar)
        Array(masks).each do |m|
          y0, x0, y1, x1 = Array(m['box_2d']).map(&:to_f)
          next unless y1 && x1

          left = (x0 / 1000 * width).floor.clamp(0, width - 1)
          top = (y0 / 1000 * height).floor.clamp(0, height - 1)
          w = ((x1 - x0) / 1000 * width).ceil.clamp(1, width - left)
          h = ((y1 - y0) / 1000 * height).ceil.clamp(1, height - top)
          png = m['mask'].to_s.sub(%r{\Adata:image/\w+;base64,}, '')
          next if png.empty?

          prob = Vips::Image.new_from_buffer(Base64.decode64(png), '')
          prob = prob.extract_band(0) if prob.bands > 1
          prob = prob.resize(w.to_f / prob.width, vscale: h.to_f / prob.height)
          prob = prob.crop(0, 0, [w, prob.width].min, [h, prob.height].min).embed(0, 0, w, h)
          piece = (prob > 127).ifthenelse(255, 0).cast(:uchar)
          region = canvas.crop(left, top, w, h)
          canvas = canvas.insert((region | piece).cast(:uchar), left, top)
        end
        canvas
      end

      def rgb(image)
        image = image.colourspace(:srgb) unless image.interpretation == :srgb
        image.bands > 3 ? image.extract_band(0, n: 3) : image
      end
    end
  end
end
