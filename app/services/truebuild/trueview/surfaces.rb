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

      VERSION = 9       # 1 text segmentation, 2 unchecked, 3 to 5 earlier checks, 6 overlapping, 7 roof took the gable, 8 two tries
      MIN_FIT = 4       # Claude's 1 to 5: 4 allows a little overspill, never the wrong thing
      PAINTER = 'nb2-lite'
      MAGENTA = [255, 0, 255]
      MAGENTA_DE = 45   # CIE dE76 from pure magenta that still counts as painted
      RETRY_FAILED_AFTER = 30.minutes
      MIN_PRESENT = 0.003 # share of the photo; less is not really in it

      # [key, matches a finish's surface name, what to outline]
      CATEGORIES = [
        ['cabinets', /cabinet|vanit|lav|hw /i,
         'the cabinet doors, drawer fronts and cabinet boxes, including an island base and any vanity. Not countertops, appliances, sinks, stools, chairs or the floor'],
        ['appliances', /appliance/i,
         'the kitchen appliances: refrigerator, range or cooktop, range hood or over the range microwave, and dishwasher. Not cabinets or countertops'],
        ['countertop', /counter/i, 'the countertops, including an island top and any short backsplash lip of the same material. Not the sink'],
        ['backsplash', /backsplash/i,
         'the backsplash: the wall surface between the countertop and the upper cabinets. Not the range, microwave, hood, outlets, window or anything on the counter'],
        ['flooring', /floor|carpet/i, 'the floor. Not rugs, furniture legs or cabinets'],
        ['accent wall', /accent|wall ?board/i,
         'the single largest flat interior wall facing the camera, from floor or countertop to ceiling. Not the ceiling, ' \
         'cabinets, backsplash, windows, doors, mirrors, light fixtures or any other wall'],
        ['siding', /siding|shake/i, "the main house's exterior wall siding. Not trim, windows, doors, roof, skirting, porch or neighboring houses"],
        ['shutters', /shutter/i, 'the window shutters on the main house'],
        ['shingles', /shingle|roof/i,
         "only the sloped roof planes of the main house that are covered in asphalt shingles, above the gutters and eaves. " \
         'The triangular gable wall under the roof peak (often covered in shakes or siding) is a wall, not roof: leave it ' \
         'as it is, along with the trim, fascia and gutters'],
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
        carried_over(source_url, key) || find!(source_url, source_bytes, key)
      rescue ActiveRecord::RecordNotUnique
        TruebuildSurfaceMask.find_by(source_url: source_url, surface: key, version: VERSION)
      end

      # Lite's painting and Claude's judging both vary run to run: Bay Port's
      # backsplash scored 4 once and 2 twice. A third try costs about 5 cents.
      OUTLINE_ATTEMPTS = 3

      # Paints, measures and checks the outline; a rejected outline of a
      # surface that is there is painted once more with Claude's note on what
      # was wrong ("it included the microwave").
      # What an outline was made from: a version bump for one surface keeps
      # the others' accepted outlines rather than drawing them again.
      def digest(key)
        Digest::SHA256.hexdigest(CATEGORIES.find { |k, _, _| k == key }.last + paint_prompt('x'))[0, 16]
      end

      def carried_over(source_url, key)
        old = TruebuildSurfaceMask.where(source_url: source_url, surface: key, status: 'done').where('version < ?', VERSION)
                                  .order(version: :desc).find { |m| m.present? && m.usage['digest'] == digest(key) }
        return nil unless old

        TruebuildSurfaceMask.create!(old.attributes.except('id', 'created_at', 'updated_at').merge('version' => VERSION,
                                                                                                    'usage' => old.usage.merge('carried_from' => old.id)))
      end

      # A reviewer flagged this outline: outline it again with their note,
      # then cut every drawing of that surface in the photo again (free).
      def redo!(mask, note)
        source = Trueview.fetch_source(mask.source_url)
        mask.destroy!
        fresh = find!(mask.source_url, source[:bytes], mask.surface, correction: note)
        TruebuildRender.where(source_url: mask.source_url, purpose: 'layer', status: 'done').where.not(image_url: nil)
                       .select { |r| category(r.selection.first&.dig('surface')) == mask.surface }.each do |old|
          old.update!(status: 'superseded')
          TruebuildRender.create!(old.attributes.except('id', 'created_at', 'updated_at', 'layer_url', 'mask_coverage', 'lab_run')
                                     .merge('status' => 'queued', 'usage' => old.usage.merge('recut_from' => old.id).except('mask_version')))
                         .tap { |r| TruebuildRenderJob.set(queue: :low).perform_later(r.id) }
        end
        fresh
      end

      def find!(source_url, source_bytes, key, correction: nil)
        description = CATEGORIES.find { |k, _, _| k == key }.last
        image = rgb(Vips::Image.new_from_buffer(source_bytes, ''))
        aspect = image.width.to_f / image.height
        spec = MODELS.fetch(PAINTER)
        spent = 0.0
        attempts = []
        mask = verdict = result = nil
        OUTLINE_ATTEMPTS.times do
          result = Providers::Gemini.edit(spec, { bytes: source_bytes, mime: 'image/jpeg' },
                                          paint_prompt(description, attempts.last&.dig('note') || correction), aspect: aspect)
          spent += Trueview.cost(spec, result[:usage])
          raise Trueview::Error, 'The model changed the framing while outlining' if Trueview.reframed_by(result, aspect) > Trueview::FRAMING_TOLERANCE

          mask = without_others(magenta(Vips::Image.new_from_buffer(result[:bytes], ''), image.width, image.height),
                                source_url, key)
          verdict = (mask.avg / 255.0).positive? ? check(image, mask, key, description) : { 'present' => false, 'fit' => 0 }
          spent += verdict['cost_usd'].to_f
          attempts << verdict
          break if !verdict['present'] || verdict['fit'].to_i >= MIN_FIT
        end
        # A wrong outline would paint the wrong thing in every color: no
        # layer for that surface is better. An absent surface is no layer too.
        coverage = verdict['present'] && verdict['fit'].to_i >= MIN_FIT ? (mask.avg / 255.0).round(4) : 0
        url = Trueview.store_bytes(mask.pngsave_buffer(compression: 9), 'image/png',
                                   "truebuild/trueview/masks/#{Digest::SHA256.hexdigest(source_url)[0, 16]}-#{key.parameterize}-v#{VERSION}.png")
        TruebuildSurfaceMask.create!(source_url: source_url, surface: key, version: VERSION, mask_url: url, coverage: coverage,
                                     model: result[:model], error: verdict['note'].presence,
                                     usage: { 'cost_usd' => spent.round(4), 'attempts' => attempts.map { |a| a.except('cost_usd') },
                                              'digest' => (digest(key) unless correction) }.compact)
      rescue Trueview::Error, Vips::Error, Catalog::PriceBooks::ClaudeClient::Error => e
        TruebuildSurfaceMask.create!(source_url: source_url, surface: key, version: VERSION, status: 'failed', error: e.message.first(500))
      end

      # Surfaces never overlap, so whatever another accepted outline of this
      # photo already covers is not this one. Bay Port's backsplash took in
      # the cabinets' edges and the accent wall ran onto the cabinets.
      def without_others(mask, source_url, key)
        TruebuildSurfaceMask.where(source_url: source_url, version: VERSION, status: 'done').where.not(surface: key)
                            .select(&:present?).reduce(mask) do |m, other|
          o = Vips::Image.new_from_buffer(Trueview.fetch_source(other.mask_url)[:bytes], '')
          o = o.extract_band(0) if o.bands > 1
          (Layer.fit(o, m.width, m.height) > 127).ifthenelse(0, m).cast(:uchar)
        end
      end

      CHECK_TOOL = {
        name: 'judge_outline',
        description: 'Judge whether the magenta area is exactly the named surface.',
        input_schema: {
          type: 'object',
          properties: {
            present: { type: 'boolean', description: 'Looking ONLY at the first image (the untouched photo): it really shows this surface.' },
            fit: { type: 'integer', minimum: 1, maximum: 5,
                   description: '5 exact; 4 the surface with only small overspill onto neighbors (a few pixels of a stool, a sliver ' \
                                'of trim); 3 mostly the surface but a clearly visible extra area; 2 a large part is something else; ' \
                                '1 the wrong thing' },
            note: { type: 'string', description: 'One short sentence: what is wrong, if anything.' }
          },
          required: %w[present fit]
        }
      }.freeze

      # Claude looks at the photo and the outline over it and says whether
      # the outline is the surface, and whether the photo shows it at all.
      # Asked for shutters on a house with none, Lite painted shutter-shaped
      # strips beside the windows, and filled in magenta they looked like
      # shutters; presence is judged on the untouched photo alone. A yes or
      # no on the outline was either too lenient or, asked to be strict,
      # rejected cabinets over a few pixels of stool, so it is a 1 to 5 fit.
      def check(image, mask, key, description)
        look = ->(img) { Base64.strict_encode64(img.thumbnail_image(1000).jpegsave_buffer(Q: 80)) }
        tinted = (mask > 127).ifthenelse((image * 0.4 + [153, 0, 153]).cast(:uchar), image).cast(:uchar).copy(interpretation: :srgb)
        result = Catalog::PriceBooks::ClaudeClient.call(
          system: 'You check outlines of home surfaces for a home configurator. A finish will be painted inside the ' \
                  'outline, so what matters is whether it would paint the right thing.',
          tool: CHECK_TOOL, max_tokens: 400, temperature: 0,
          content: [{ type: 'text', text: 'Photo:' }, { type: 'image', source: { type: 'base64', media_type: 'image/jpeg', data: look.(image) } },
                    { type: 'text', text: "First, from that photo alone: does it show #{key}? Then the same photo with the " \
                                          "outline filled in magenta. It should be #{key}: #{description}." },
                    { type: 'image', source: { type: 'base64', media_type: 'image/jpeg', data: look.(tinted) } }]
        )
        result[:input].slice('present', 'fit', 'note')
                      .merge('cost_usd' => Catalog::PriceBooks::ClaudeClient.cost_usd(result[:input_tokens], result[:output_tokens]).round(4))
      end

      def paint_prompt(description, correction = nil)
        fix = correction.present? ? "\nA previous attempt was wrong: #{correction} Do not repeat that." : ''
        <<~TEXT.strip
          This is a real photograph. Paint #{description} solid, flat, pure magenta (#FF00FF): no shading, texture or
          reflections on it. Change nothing else at all: every other pixel, the framing, the camera and the objects in
          front of it stay exactly as they are. If the photo does not show any, return the photo unchanged.#{fix}
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
