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

      MIN_DELTA = 10   # CIE dE76; a change this size is certainly the surface
      WEAK_DELTA = 4   # a change this size counts when it joins a certain one
      DRIFT_MARGIN = 6 # above the median change, which is the model's drift
      REGION_PX = 400  # width the regions are worked out at
      MIN_REGION = 0.001 # share of the photo; smaller regions are noise
      MAX_HOLE = 0.02  # share of the photo; enclosed gaps up to this are filled
      FEATHER = 2.5
      VERSION = 17     # bump when the cut or its check changes, so old layers are re-cut (16: checked against the sample, 17: never cut without an outline)
      EDGE_FEATHER = 1.2
      OUTLINE_GROW = 2 # pixels at the photo's 1600 width

      # => { bytes:, mime:, coverage: } coverage is the share of the photo kept.
      #
      # A pixel-by-pixel threshold left a new floor in patches wherever the new
      # color sat close to the old one. The surface is treated as regions
      # instead: a change counts if it is certain, or if it is slight but joined
      # to a certain one, and small gaps enclosed by the surface are filled.
      # Inside a gap the rendering matches the photo anyway, so filling costs
      # nothing where the model left something alone.
      #
      # mask: the surface's outline in the original photo (Surfaces). When
      # given, the layer is the drawing inside it and nothing else; the
      # change-based cut is only for surfaces without an outline.
      def build(original_bytes, render_bytes, mask: nil)
        orig = rgb(Vips::Image.new_from_buffer(original_bytes, ''))
        edit = rgb(Vips::Image.new_from_buffer(render_bytes, ''))
        edit = fit(edit, orig.width, orig.height)
        return outlined(edit, mask, orig.width, orig.height) if mask

        delta = orig.gaussblur(1.5).colourspace(:lab).dE76(edit.gaussblur(1.5).colourspace(:lab))
        drift = delta.percent(50)
        small = delta.resize(REGION_PX.to_f / delta.width)
        region = regions(small, strong: [MIN_DELTA, drift + DRIFT_MARGIN].max, weak: [WEAK_DELTA, drift + 3].max)

        mask = region.resize(orig.width.to_f / region.width, vscale: orig.height.to_f / region.height, kernel: :linear)
                     .crop(0, 0, orig.width, orig.height)
        mask = (mask > 127).ifthenelse(255, 0).cast(:uchar)
        alpha = mask.gaussblur(FEATHER).cast(:uchar)

        { bytes: edit.bandjoin(alpha).webpsave_buffer(Q: 82, alpha_q: 90), mime: 'image/webp',
          coverage: (mask.avg / 255.0).round(4) }
      end

      def outlined(edit, mask, width, height)
        mask = mask.extract_band(0) if mask.bands > 1
        mask = fit(mask, width, height)
        mask = (mask > 127).ifthenelse(255, 0).cast(:uchar)
        # The painted outline runs a pixel or two inside the real edge; grow
        # it so no sliver of the old finish shows along cabinet edges.
        mask = mask.morph(disc(OUTLINE_GROW), :dilate) if OUTLINE_GROW.positive?
        alpha = mask.gaussblur(EDGE_FEATHER).cast(:uchar)
        { bytes: edit.bandjoin(alpha).webpsave_buffer(Q: 82, alpha_q: 90), mime: 'image/webp',
          coverage: (mask.avg / 255.0).round(4) }
      end

      # Hysteresis on the change map, then hole filling. A 0/255 image the
      # size of small.
      def regions(small, strong:, weak:)
        w = small.width
        h = small.height
        n = w * h
        values = small.cast(:float).write_to_memory.unpack('e*')
        keep = Array.new(n, false)
        seen = Array.new(n, false)
        min_size = (n * MIN_REGION).ceil

        n.times do |i|
          next if seen[i] || values[i] <= weak

          members = flood(i, w, h, seen) { |k| values[k] > weak }
          next if members.size < min_size || members.none? { |k| values[k] > strong }

          members.each { |k| keep[k] = true }
        end

        # Gaps in the surface: unkept areas that do not reach the photo's edge.
        gap_seen = Array.new(n, false)
        max_hole = (n * MAX_HOLE).floor
        n.times do |i|
          next if gap_seen[i] || keep[i]

          members = flood(i, w, h, gap_seen) { |k| !keep[k] }
          next if members.size > max_hole
          next if members.any? { |k| (x = k % w).zero? || x == w - 1 || (y = k / w).zero? || y == h - 1 }

          members.each { |k| keep[k] = true }
        end

        bytes = keep.map { |k| k ? 255 : 0 }.pack('C*')
        Vips::Image.new_from_memory(bytes, w, h, 1, :uchar).morph(disc(1), :dilate).morph(disc(1), :erode)
      end

      def flood(start, w, h, seen)
        seen[start] = true
        stack = [start]
        members = []
        until stack.empty?
          j = stack.pop
          members << j
          x = j % w
          [(j - 1 if x.positive?), (j + 1 if x < w - 1), (j - w if j >= w), (j + w if j < w * (h - 1))].each do |k|
            next if k.nil? || seen[k] || !yield(k)

            seen[k] = true
            stack << k
          end
        end
        members
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

        out = image.resize(width.to_f / image.width, vscale: height.to_f / image.height)
        out.crop(0, 0, [width, out.width].min, [height, out.height].min).embed(0, 0, width, height, extend: :copy)
      end

      def disc(radius)
        size = radius * 2 + 1
        Vips::Image.new_from_array(Array.new(size) { |y| Array.new(size) { |x| (x - radius)**2 + (y - radius)**2 <= radius**2 ? 255 : 128 } })
      end
    end
  end
end
