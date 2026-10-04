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

      VERSION = 14      # 1 text segmentation, 2 unchecked, 3 to 5 earlier checks, 6 overlapping, 7 roof took the gable, 8 two tries,
                        # 9 presence judged beside the overlay, 10 presence asked too strictly, 11 carried outlines,
                        # 12 edges by precedence and a check for spill onto neighbors (an outline whose description
                        # did not change is carried over, free), 13 cabinets up to the ceiling, spill sized,
                        # thin surfaces kept, 14 the crown molding on top of cabinets is the cabinets'
      MIN_FIT = 4       # Claude's 1 to 5: 4 allows a little overspill, never the wrong thing
      PAINTER = 'nb2-lite'
      MAGENTA = [255, 0, 255]
      MAGENTA_DE = 45   # CIE dE76 from pure magenta that still counts as painted
      RETRY_FAILED_AFTER = 30.minutes
      MIN_PRESENT = 0.003 # share of the photo; less is not really in it
      # Thin surfaces are thin: Brighton's corner posts scored 5 on 0.09% of
      # the photo and were thrown out as not there.
      MIN_PRESENT_BY_SURFACE = { 'corner posts' => 0.0003, 'shutters' => 0.001 }.freeze

      def min_present(key)
        MIN_PRESENT_BY_SURFACE.fetch(key.to_s, MIN_PRESENT)
      end

      # [key, matches a finish's surface name, what to outline]
      CATEGORIES = [
        ['cabinets', /cabinet|vanit|lav|hw /i,
         'the cabinet doors, drawer fronts and cabinet boxes: every upper and lower cabinet, including the one above the ' \
         'range hood or microwave and any that rise to the ceiling, the crown molding and trim fitted on top of the ' \
         'cabinets (finished to match them), an island base and any vanity, down to the underside of the countertop. Not ' \
         'the crown molding where the walls meet the ceiling away from the cabinets. Not the countertop or its front edge (the band of countertop material facing the camera above ' \
         'the doors), appliances, sinks, stools, chairs or the floor'],
        # A refrigerator option on a photo with no refrigerator is skipped
        # rather than drawn and rejected (a side-by-side on a kitchen photo
        # that shows only the range).
        ['refrigerator', /refrigerator|\brefer\b|fridge/i, 'the refrigerator only. Not other appliances, cabinets or countertops'],
        ['appliances', /appliance/i,
         'the kitchen appliances: refrigerator, range or cooktop, range hood or over the range microwave, and dishwasher. Not cabinets or countertops'],
        ['countertop', /counter/i,
         'the countertops: the top surface and its front edge facing the camera (the band of the same material above the ' \
         'cabinet doors), an island top, and any short backsplash lip of the same material. Not the sink or the cabinets'],
        ['backsplash', /backsplash/i,
         'the backsplash: the tile, brick or panel on the wall above the countertops, everywhere it runs (beside a window, ' \
         'behind the range up to the hood). Not the range, microwave, hood, outlets, window, cabinets or anything on the counter'],
        ['flooring', /floor|carpet/i, 'the floor. Not rugs, furniture legs or cabinets'],
        ['accent wall', /accent|wall ?board/i,
         'one painted wall (plain drywall or wall panel) facing the camera, the largest one, from floor or countertop to ' \
         'ceiling. Exactly one wall. Never any part of a tub or shower surround (fiberglass, acrylic or tile) or its edge, ' \
         'trim or door frame, never tile, brick, stone or a backsplash, and not the ceiling, cabinets, windows, doors, ' \
         'mirrors, light fixtures or any other wall'],
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

      # What a finish's surface covers in a photo, in words.
      def describe(surface)
        CATEGORIES.find { |_, re, _| surface.to_s.match?(re) }&.last
      end

      # The mask record for a photo and surface, finding it on first use.
      # nil for a surface no category covers (the layer falls back to the
      # change-based cut).
      def mask_for(source_url, source_bytes, surface)
        key = category(surface) or return nil
        found = TruebuildSurfaceMask.find_by(source_url: source_url, surface: key, version: VERSION)
        return found if found && !retry_due?(found)
        return found if found && found.status == 'failed' && !claim(found)

        if found && rejected?(found)
          # Claude found the surface but turned the outline down: outline it
          # again, told why, a few times before taking it as not drawable.
          # One job claims it; the others drawing this surface now skip, and
          # are drawn again once the new outline passes.
          return found unless claim(found)

          found.destroy!
          fresh = find!(source_url, source_bytes, key, correction: found.error, tries: found.usage['tries'].to_i + 1)
          redraw_skipped(source_url, key) if fresh.present?
          return fresh
        end
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

        # Carried outlines get the presence question too: it is new since some were made.
        seen = presence(rgb(Vips::Image.new_from_buffer(Trueview.fetch_source(source_url)[:bytes], '')), key,
                        CATEGORIES.find { |k, _, _| k == key }.last)
        TruebuildSurfaceMask.create!(old.attributes.except('id', 'created_at', 'updated_at')
                                        .merge('version' => VERSION, 'coverage' => seen['present'] ? old.coverage : 0,
                                               'error' => seen['present'] ? old.error : seen['note'],
                                               'usage' => old.usage.merge('carried_from' => old.id, 'presence' => seen)))
      end

      # A reviewer flagged this outline: outline it again with their note,
      # then cut every drawing of that surface in the photo again (free).
      def redo!(mask, note)
        source = Trueview.fetch_source(mask.source_url)
        pattern = mask.usage['pattern_redo']
        mask.destroy!
        fresh = find!(mask.source_url, source[:bytes], mask.surface, correction: note)
        # Redone for a pattern (Patterns): never again for one, or it could loop.
        fresh.update_columns(usage: fresh.usage.merge('pattern_redo' => true)) if pattern && fresh.persisted?
        # Held-back drawings too: a wrong outline is often why they were held.
        TruebuildRender.where(source_url: mask.source_url, purpose: 'layer', status: %w[done rejected]).where.not(image_url: nil)
                       .select { |r| category(r.selection.first&.dig('surface')) == mask.surface }.each do |old|
          old.update!(status: 'superseded')
          TruebuildRender.create!(old.attributes.except('id', 'created_at', 'updated_at', 'layer_url', 'mask_coverage', 'lab_run')
                                     .merge('status' => 'queued', 'usage' => old.usage.merge('recut_from' => old.id).except('mask_version')))
                         .tap { |r| TruebuildRenderJob.set(queue: :low).perform_later(r.id) }
        end
        fresh
      end

      OUTLINE_TRIES = 3 # outlines Claude rejects before a surface is left undrawn on a photo

      # The surface is in the photo, but every attempt at its outline was
      # turned down: stored as no outline, so every color was skipped as "not
      # in this photo" and nothing tried again outside a factory run.
      def rejected?(mask)
        mask.status == 'done' && mask.coverage.to_f.zero? && Array(mask.usage['attempts']).last.to_h['present'] == true
      end

      # Worth another outline now: an error (not framing) or a rejection,
      # half an hour on, within OUTLINE_TRIES.
      def retry_due?(mask)
        return false if mask.updated_at > RETRY_FAILED_AFTER.ago
        return !mask.error.to_s.include?('framing') if mask.status == 'failed'

        rejected?(mask) && mask.usage['tries'].to_i + 1 < OUTLINE_TRIES
      end

      # Due for another outline now, whenever it was turned down.
      def make_due!(mask)
        mask.update_columns(updated_at: (RETRY_FAILED_AFTER + 1.minute).ago)
      end

      # Only one job outlines a surface again: the one whose update moves it.
      def claim(mask)
        TruebuildSurfaceMask.where(id: mask.id, updated_at: mask.updated_at).update_all(updated_at: Time.current) == 1
      end

      # Drawings of this surface skipped as "not in this photo" while it had
      # no outline: set aside, so the model's next queue draws them.
      def redraw_skipped(source_url, key)
        rows = TruebuildRender.where(source_url: source_url, purpose: 'layer', status: 'skipped').to_a
                              .select { |r| category(r.selection.first&.dig('surface')) == key }
        TruebuildRender.where(id: rows.map(&:id)).update_all(status: 'superseded', updated_at: Time.current)
        variants = rows.filter_map(&:catalog_plan_variant_id).uniq
        CatalogPlanVariant.where(id: variants).find_each do |v|
          run = TruebuildFactoryRun.find_by(id: rows.find { |r| r.catalog_plan_variant_id == v.id }&.usage&.dig('factory_run_id'))
          Buyer.new(nil, v).queue_missing!(run: run&.status == 'running' ? run : nil)
        end
      end

      def find!(source_url, source_bytes, key, correction: nil, tries: 0)
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
                                              'digest' => (digest(key) unless correction), 'tries' => (tries if tries.positive?) }.compact)
      rescue Trueview::Error, Vips::Error, Catalog::PriceBooks::ClaudeClient::Error => e
        TruebuildSurfaceMask.create!(source_url: source_url, surface: key, version: VERSION, status: 'failed', error: e.message.first(500))
      end

      # Surfaces that share pixels: an appliance package changes the
      # refrigerator too.
      SHARED = { 'refrigerator' => ['appliances'], 'appliances' => ['refrigerator'] }.freeze

      # Where two surfaces meet, the edge belongs to the one earlier here,
      # whichever was outlined first. First come had Aspire 082's cabinets
      # take the countertop's front edge (white doors under a white and grey
      # counter), so every countertop left the edge in the old finish and
      # every cabinet color painted over it. Light colors side by side are
      # where the painter cannot see an edge, so the order decides, not it.
      PRECEDENCE = ['countertop', 'backsplash', 'refrigerator', 'appliances', 'cabinets', 'flooring', 'accent wall',
                    'shutters', 'corner posts', 'shingles', 'siding'].freeze

      def outranks?(key, other)
        (PRECEDENCE.index(key) || PRECEDENCE.size) < (PRECEDENCE.index(other) || PRECEDENCE.size)
      end

      # Surfaces never overlap: whatever an accepted outline of a surface that
      # outranks this one covers is not this one. Bay Port's backsplash took
      # in the cabinets' edges and the accent wall ran onto the cabinets.
      def without_others(mask, source_url, key)
        blocked = claimed_above(source_url, key, mask.width, mask.height)
        blocked ? (blocked > 127).ifthenelse(0, mask).cast(:uchar) : mask
      end

      # The pixels surfaces that outrank key hold in this photo, as one 0/255
      # image of the given size, or nil. Used again when a layer is cut, so an
      # outline made before an outranking one never paints over its edge.
      def claimed_above(source_url, key, width, height)
        others = TruebuildSurfaceMask.where(source_url: source_url, version: VERSION, status: 'done')
                                     .where.not(surface: [key, *SHARED[key]]).select { |o| o.present? && outranks?(o.surface, key) }
        return nil if others.empty?

        others.map do |other|
          o = Vips::Image.new_from_buffer(Trueview.fetch_source(other.mask_url)[:bytes], '')
          o = o.extract_band(0) if o.bands > 1
          Layer.fit(o, width, height)
        end.reduce { |a, b| (a > 127) | (b > 127) }.ifthenelse(255, 0).cast(:uchar)
      end

      # What an outline may spill onto, for the check to name. Spill onto a
      # surface that outranks this one is harmless (the cut leaves it to
      # that surface); spill onto anything else turns the outline down.
      SPILL_TARGETS = ['none', 'countertop', 'backsplash', 'refrigerator', 'appliances', 'cabinets', 'flooring', 'accent wall',
                       'tub or shower surround', 'another wall', 'ceiling', 'trim, door or window frame', 'sink or faucet',
                       'furniture or decor', 'siding', 'shutters', 'shingles', 'other'].freeze

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
            spills_onto: { type: 'string', enum: SPILL_TARGETS,
                           description: 'If the magenta covers part of a neighboring surface, which one (the largest); "none" ' \
                                        'if it does not.' },
            spill_size: { type: 'string', enum: %w[none slight clear],
                          description: 'slight: a thin sliver or a few small spots a buyer would not notice; clear: an area a buyer ' \
                                       'would see painted wrong.' },
            misses: { type: 'string',
                      description: 'A clearly visible part of the surface left out of the magenta, in a few words ("the ' \
                                   'cabinet above the microwave", "the floor left of the vanity"), or "none".' },
            walls: { type: 'integer', description: 'For an accent wall only: how many separate walls the magenta covers.' },
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
      PRESENCE_TOOL = {
        name: 'judge_presence',
        description: 'Say whether the photo shows the named surface.',
        input_schema: {
          type: 'object',
          properties: { present: { type: 'boolean' }, note: { type: 'string', description: 'One short sentence.' } },
          required: ['present']
        }
      }.freeze

      def look(img)
        Base64.strict_encode64(img.thumbnail_image(1000).jpegsave_buffer(Q: 80))
      end

      # Asked of the untouched photo alone. With a painted outline beside it,
      # Claude twice took shutter-shaped paint on Bay Port (which has no
      # shutters) for shutters.
      def presence(image, key, description)
        result = Catalog::PriceBooks::ClaudeClient.call(
          system: 'You look at photos of manufactured homes for a home configurator. Answer only from what is visible.',
          tool: PRESENCE_TOOL, max_tokens: 200, temperature: 0,
          content: [{ type: 'image', source: { type: 'base64', media_type: 'image/jpeg', data: look(image) } },
                    { type: 'text', text: "A buyer is choosing a new finish for the #{key} (#{description}). Can you see at least " \
                                          "part of the #{key} in this photo, so it could be shown in a new finish? It does not " \
                                          'need to be complete or look special already: an accent wall is any large plain wall, ' \
                                          'appliances are any of them that are visible. Answer no only if none of it is visible.' }]
        )
        result[:input].slice('present', 'note')
                      .merge('cost_usd' => Catalog::PriceBooks::ClaudeClient.cost_usd(result[:input_tokens], result[:output_tokens]).round(4))
      end

      def check(image, mask, key, description)
        seen = presence(image, key, description)
        return seen.merge('fit' => 0) unless seen['present']

        tinted = (mask > 127).ifthenelse((image * 0.4 + [153, 0, 153]).cast(:uchar), image).cast(:uchar).copy(interpretation: :srgb)
        result = Catalog::PriceBooks::ClaudeClient.call(
          system: 'You check outlines of home surfaces for a home configurator. A finish will be painted inside the ' \
                  'outline, so what matters is whether it would paint the right thing.',
          tool: CHECK_TOOL, max_tokens: 400, temperature: 0,
          content: [{ type: 'text', text: 'Photo:' }, { type: 'image', source: { type: 'base64', media_type: 'image/jpeg', data: look(image) } },
                    { type: 'text', text: "The same photo with an outline filled in magenta. It should be #{key}: #{description}. " \
                                          'The surface is in the photo; judge only the outline (answer present: true). Look ' \
                                          'closely where light colors meet (white doors under a white counter edge, a pale wall ' \
                                          'beside a white tub surround) and at the top of the cabinets (one above the microwave ' \
                                          'or hood, ones reaching the ceiling, crown molding fitted on top of them): that is ' \
                                          "where outlines go wrong.#{fine_overlap(key)}" },
                    { type: 'image', source: { type: 'base64', media_type: 'image/jpeg', data: look(tinted) } }]
        )
        cost = Catalog::PriceBooks::ClaudeClient.cost_usd(result[:input_tokens], result[:output_tokens])
        verdict = result[:input].slice('fit', 'note', 'spills_onto', 'spill_size', 'misses', 'walls')
        verdict['fit'] = strict_fit(key, verdict)
        verdict.merge('present' => true, 'cost_usd' => (cost + seen['cost_usd'].to_f).round(4))
      end

      # Surfaces this one may overlap without harm: each keeps its own pixels
      # when layers are cut, so Claude should not mark the outline down for it.
      def fine_overlap(key)
        above = PRECEDENCE.select { |o| o != key && outranks?(o, key) }
        above.empty? ? '' : " Overlap with the #{above.join(', ')} does not matter (each keeps its own pixels): do not mark it down."
      end

      # A 4 allows a few stray pixels, not a neighbor: Aspire 082's bath accent
      # wall took three walls and the shower surround's edge and scored 4. But
      # kitchen cabinets that touched the range hood are fine: the appliances
      # outrank them, and the cut keeps the hood theirs.
      def strict_fit(key, verdict)
        fit = verdict['fit'].to_i
        onto = verdict['spills_onto'].to_s
        harmless = onto.blank? || onto == 'none' || outranks?(onto, key) || verdict['spill_size'] == 'slight'
        missed = verdict['misses'].present? && !verdict['misses'].to_s.strip.match?(/\Anone\.?\z/i)
        # Marked down for nothing but a slight or harmless spill: Brighton's
        # roof and Woodward's counter scored 3 for "slightly" touching trim.
        fit = MIN_FIT if harmless && !missed && fit == MIN_FIT - 1 && verdict['spill_size'].present?
        fit = [fit, MIN_FIT - 1].min unless harmless
        # Woodward's kitchen cabinets left out the one above the microwave.
        fit = [fit, MIN_FIT - 1].min if missed
        fit = [fit, 2].min if key == 'accent wall' && verdict['walls'].to_i > 1
        fit
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
