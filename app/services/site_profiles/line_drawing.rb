# frozen_string_literal: true

require 'vips'

module SiteProfiles
  # Tells a floor plan (or any black-on-white line drawing) from a photograph
  # by its pixels.
  #
  # The name check in PageDigest (FLOOR_PLAN) only works when a file or its alt
  # text says "floor plan". Plenty do not: Coastal Breeze's plans were named by
  # model number ("16803.png"), and 12 of the 24 images in their scanned gallery
  # were floor plans (2026-11-13). A gallery called "Inside Our Homes" full of
  # line drawings reads as a mistake.
  #
  # A line drawing is mostly white paper with no colour in it. Measured on that
  # site: the 12 plans were 56 to 88 percent near-white with average colour 0.0
  # to 0.3. The 32 photos and renderings were at most 28 percent near-white
  # with average colour 6.8 or more. A black and white photograph has no colour
  # either, but it is not mostly white, so it passes.
  module LineDrawing
    WHITE_SHARE = 0.45
    MAX_COLOUR = 4.0
    # Small is enough to judge, and keeps memory flat on a 12 MB upload.
    SAMPLE = 200

    module_function

    def line_drawing?(bytes)
      white, colour = measure(bytes)
      white >= WHITE_SHARE && colour < MAX_COLOUR
    rescue StandardError
      # Anything we cannot read is left to the rest of the pipeline, which
      # already drops images that will not load.
      false
    end

    # [share of near-white pixels, average colour (max channel minus min)]
    def measure(bytes)
      img = Vips::Image.thumbnail_buffer(bytes.to_s, SAMPLE).copy_memory
      img = img.flatten(background: [255, 255, 255]) if img.has_alpha?
      img = img.colourspace(:srgb) unless img.interpretation == :srgb
      img = img.extract_band(0, n: 3) if img.bands > 3
      img = img.bandjoin([img, img]) if img.bands == 1

      r, g, b = img.bandsplit
      high = (r > g).ifthenelse(r, g)
      high = (high > b).ifthenelse(high, b)
      low = (r < g).ifthenelse(r, g)
      low = (low < b).ifthenelse(low, b)

      [(low > 225).ifthenelse(1, 0).avg, (high - low).avg]
    end
  end
end
