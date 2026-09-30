# frozen_string_literal: true

require 'vips'

module Truebuild
  module Trueview
    # Cuts a one-finish rendering down to the pixels that finish changed.
    #
    # A layer is drawn with only one surface changed, so comparing it with
    # the original photo finds that surface: pixels whose color moved by
    # more than the model's overall drift. What is left is the rendering
    # with a soft-edged alpha mask, saved as WebP at the photo's exact size,
    # so any set of layers stacks on the photo with plain image tags.
    module Layer
      module_function

      MIN_DELTA = 10   # CIE dE76; below this a change is not visible
      DRIFT_MARGIN = 6 # above the median change, which is the model's drift
      FEATHER = 2.0

      # => { bytes:, mime:, coverage: } coverage is the share of the photo kept.
      def build(original_bytes, render_bytes)
        orig = rgb(Vips::Image.new_from_buffer(original_bytes, ''))
        edit = rgb(Vips::Image.new_from_buffer(render_bytes, ''))
        edit = fit(edit, orig.width, orig.height)

        delta = orig.gaussblur(1.5).colourspace(:lab).dE76(edit.gaussblur(1.5).colourspace(:lab))
        threshold = [MIN_DELTA, delta.percent(50) + DRIFT_MARGIN].max
        mask = (delta > threshold).ifthenelse(255, 0).cast(:uchar)
        # Speckle out, holes in, then a soft edge.
        mask = mask.median(5).morph(disc(4), :dilate).morph(disc(4), :erode)
        alpha = mask.gaussblur(FEATHER).cast(:uchar)

        { bytes: edit.bandjoin(alpha).webpsave_buffer(Q: 82, alpha_q: 90), mime: 'image/webp',
          coverage: (mask.avg / 255.0).round(4) }
      end

      def rgb(image)
        image = image.colourspace(:srgb) unless image.interpretation == :srgb
        image = image.flatten(background: [255, 255, 255]) if image.has_alpha?
        image.bands > 3 ? image.extract_band(0, n: 3) : image
      end

      # Image models return their own size (Lite draws at 1K); stretch back
      # onto the photo so the layer lines up pixel for pixel.
      def fit(image, width, height)
        return image if image.width == width && image.height == height

        image.resize(width.to_f / image.width, vscale: height.to_f / image.height).crop(0, 0, width, height)
      end

      def disc(radius)
        size = radius * 2 + 1
        Vips::Image.new_from_array(Array.new(size) { |y| Array.new(size) { |x| (x - radius)**2 + (y - radius)**2 <= radius**2 ? 255 : 128 } })
      end
    end
  end
end
