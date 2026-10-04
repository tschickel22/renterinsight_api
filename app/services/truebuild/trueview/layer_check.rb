# frozen_string_literal: true

module Truebuild
  module Trueview
    # A last look at each finished layer, on the photo, before buyers see it.
    # The outline check catches a wrong outline; this catches what a right
    # outline still lets through: Bay Port's new siding stopped short of the
    # shaded porch wall, leaving the old color beside the new.
    #
    # Claude sees the photo and the photo with the layer on it and scores it
    # 1 to 5. Under MIN_SCORE the layer is drawn once more with the note,
    # then hidden from buyers and listed for review.
    #
    # A 4 gets a second, differently worded look that hunts for defects
    # region by region, and passes only if that agrees. Asking the same
    # question twice gave the same answer 100 times in 100; the second look
    # caught 5 to 7 bad drawings in 100 the first had passed (paint on every
    # wall, a stainless fridge drawn white) at about a cent a 4.
    module LayerCheck
      module_function

      MIN_SCORE = 4

      TOOL = {
        name: 'judge_layer',
        description: 'Judge a home photo rendered with one surface changed.',
        input_schema: {
          type: 'object',
          properties: {
            score: { type: 'integer', minimum: 1, maximum: 5,
                     description: '5 the named surface is fully and evenly in the new finish and nothing else changed; 4 small ' \
                                  'flaws a buyer would not notice; 3 a visible flaw (a patch of the old finish, paint on a ' \
                                  'neighboring surface, a smear); 2 clearly wrong in places; 1 wrong surface or broken image' },
            note: { type: 'string', description: 'One short sentence: the most visible flaw, if any.' }
          },
          required: %w[score]
        }
      }.freeze

      # => { 'score' =>, 'note' =>, 'ok' =>, 'cost_usd' => }
      # sample: the factory's own sample of the finish (bytes), when a decor
      # sheet has one. Without it the check could only ask whether the surface
      # changed, and Destin White cabinets drawn in the wrong white passed.
      def judge(original_bytes, layer_bytes, surface:, value:, sample: nil, hex: nil)
        photo = Surfaces.rgb(Vips::Image.new_from_buffer(original_bytes, ''))
        layer = Vips::Image.new_from_buffer(layer_bytes, '')
        layer = Layer.fit(layer, photo.width, photo.height) if layer.width != photo.width || layer.height != photo.height
        composite = photo.composite2(layer, :over).extract_band(0, n: 3).cast(:uchar).copy(interpretation: :srgb)
        result = Catalog::PriceBooks::ClaudeClient.call(
          system: 'You check renderings for a home configurator before buyers see them. Judge only what a buyer would ' \
                  'notice looking at the last image.',
          tool: TOOL, max_tokens: 300, temperature: 0,
          content: [{ type: 'text', text: 'The photo as built:' }, image(photo), *sample_content(sample, value, hex),
                    { type: 'text', text: "The same photo with the #{surface} changed to #{value}. Is all of the visible " \
                                          "#{surface} in the new finish, evenly, with nothing else changed or added?" \
                                          "#{scope(surface, value)}#{match_rule(sample, hex)}" },
                    image(composite)]
        )
        score = result[:input]['score'].to_i
        verdict = { 'score' => score, 'note' => result[:input]['note'].to_s.strip.presence, 'ok' => score >= MIN_SCORE,
                    'cost_usd' => Catalog::PriceBooks::ClaudeClient.cost_usd(result[:input_tokens], result[:output_tokens]).round(4) }
        if score == MIN_SCORE
          second = second_look(photo, composite, surface: surface, value: value, sample: sample, hex: hex)
          verdict = verdict.merge('second' => second.except('cost_usd'), 'cost_usd' => (verdict['cost_usd'] + second['cost_usd']).round(4),
                                  'ok' => second['acceptable'] != false,
                                  'note' => second['acceptable'] == false ? second['defect'] : verdict['note'])
        end
        reconsider(verdict, photo, composite, surface: surface, value: value, sample: sample, hex: hex)
      rescue Catalog::PriceBooks::ClaudeClient::Error => e
        # The check could not run: show the layer rather than hide good work,
        # and say so in review.
        { 'score' => nil, 'note' => "Not checked: #{e.message.first(120)}", 'ok' => true, 'cost_usd' => 0 }
      end

      # What counts as the surface, so other surfaces keeping their finish are
      # not marked down: a factory run's checks held back a brick backsplash
      # for not changing with the accent wall, and black appliance packages on
      # a kitchen whose appliances were already black.
      def scope(surface, value = nil)
        described = Surfaces.describe(surface)
        text = described ? " The #{surface} here means #{described}; anything else keeping its finish is correct." : ''
        if (look = OptionLook.describe(surface, value))
          text += " The option is #{value}: it must show #{look}. A different style or finish is clearly wrong: score 2."
        end
        "#{text} If the photo already showed this finish, little or no change is correct (score 4 or 5). An appliance " \
          'package may leave the range hood as it was. Anything added or doubled (a second pull or knob on a door, new ' \
          'hardware, a new object) is clearly wrong: score 2.'
      end

      # Held back for a reason that is not a defect: Summit Park's Bay Port
      # bath held back every cabinet color but one for the cabinet reflected
      # in the mirror, and its siding for the shakes in the gable, which
      # Champion sells as a separate option. Saying so in the main question
      # moved other verdicts both ways on the hand-labelled set (29 of 36 right
      # fell to 26), so the main check stays as it is and only a drawing held
      # back for one of these reasons is asked again, with the reason set aside.
      FALSE_ALARM = /reflect|mirror|gable/i
      SET_ASIDE = 'That reason is not a defect here: a reflection in a mirror, window or glass is not the surface, and ' \
                  'shakes, board and batten or other cladding in a gable that differs from the main walls is a separate ' \
                  'surface, correctly left as it was.'

      RECONSIDER = {
        name: 'reconsider',
        description: 'Judge a rendering again with a mistaken objection set aside.',
        input_schema: {
          type: 'object',
          properties: {
            other_defect: { type: 'string', description: 'Any other visible defect (old finish left on the surface itself, the new finish on a neighboring surface, a color unlike the sample, anything added), or "none".' },
            acceptable: { type: 'boolean', description: 'With that objection set aside, a buyer would accept this as the named finish.' }
          },
          required: %w[other_defect acceptable]
        }
      }.freeze

      def reconsider(verdict, photo, composite, surface:, value:, sample:, hex:)
        return verdict if verdict['ok'] || !verdict['note'].to_s.match?(FALSE_ALARM)

        result = Catalog::PriceBooks::ClaudeClient.call(
          system: 'You check renderings for a home configurator before buyers see them. Be specific and skeptical.',
          tool: RECONSIDER, max_tokens: 400, temperature: 0,
          content: [{ type: 'text', text: 'The photo as built:' }, image(photo), *sample_content(sample, value, hex),
                    { type: 'text', text: "The same photo with the #{surface} changed to #{value}. A first reviewer held it back: " \
                                          "\"#{verdict['note']}\" #{SET_ASIDE} Setting that reason aside, look again region by region." \
                                          "#{scope(surface, value)}#{match_rule(sample, hex)}" },
                    image(composite)]
        )
        input = result[:input]
        cost = Catalog::PriceBooks::ClaudeClient.cost_usd(result[:input_tokens], result[:output_tokens])
        other = input['other_defect'].to_s.strip
        passed = input['acceptable'] == true
        verdict.merge('ok' => passed, 'reconsidered' => { 'acceptable' => passed, 'other_defect' => other.first(300) },
                      'note' => passed ? verdict['note'] : (other.match?(/\Anone\b/i) ? verdict['note'] : other.first(300)),
                      'cost_usd' => (verdict['cost_usd'].to_f + cost).round(4))
      rescue Catalog::PriceBooks::ClaudeClient::Error
        verdict
      end

      SECOND = {
        name: 'find_defects',
        description: 'Look for defects in a home photo rendered with one surface changed.',
        input_schema: {
          type: 'object',
          properties: {
            old_finish_left: { type: 'string', description: 'Any visible part of the named surface still in the original finish, or "none".' },
            spilled_onto: { type: 'string', description: 'Any neighboring surface painted in the new finish, or "none".' },
            added_or_changed: { type: 'string', description: 'Anything added, removed or reshaped that the option does not call for (hardware, fixtures, objects), or "none".' },
            color_matches_sample: { type: 'boolean', description: 'The new finish matches the sample (or, with no sample, the named finish).' },
            acceptable: { type: 'boolean', description: 'A buyer would accept this as the named finish: no defect above that they would notice.' },
            defect: { type: 'string', description: 'If not acceptable, the most visible defect in one short sentence.' }
          },
          required: %w[old_finish_left spilled_onto added_or_changed color_matches_sample acceptable]
        }
      }.freeze

      # The second look at a 4: skeptical, region by region. => { 'acceptable' =>,
      # 'defect' =>, ..., 'cost_usd' => }; acceptable nil when it could not run,
      # which leaves the first verdict standing.
      def second_look(photo, composite, surface:, value:, sample:, hex:)
        result = Catalog::PriceBooks::ClaudeClient.call(
          system: 'You inspect renderings for a home configurator. Be specific and skeptical: buyers will compare this ' \
                  'against the real home.',
          tool: SECOND, max_tokens: 500, temperature: 0,
          content: [{ type: 'text', text: 'The photo as built:' }, image(photo), *sample_content(sample, value, hex),
                    { type: 'text', text: "The same photo after the #{surface} was changed to #{value}. Inspect it closely, " \
                                          "region by region, for defects before judging.#{scope(surface, value)}" },
                    image(composite)]
        )
        input = result[:input]
        defect = input['defect'].to_s.strip.presence ||
                 [input['old_finish_left'], input['spilled_onto'], input['added_or_changed']].map(&:to_s)
                                                                                                .find { |t| t.present? && !t.match?(/\Anone\b/i) }
        input.slice('old_finish_left', 'spilled_onto', 'added_or_changed', 'color_matches_sample', 'acceptable')
             .merge('defect' => defect&.first(300),
                    'cost_usd' => Catalog::PriceBooks::ClaudeClient.cost_usd(result[:input_tokens], result[:output_tokens]).round(4))
      rescue Catalog::PriceBooks::ClaudeClient::Error => e
        { 'acceptable' => nil, 'defect' => "Second look not run: #{e.message.first(120)}", 'cost_usd' => 0 }
      end

      def sample_content(sample, value, hex)
        return [] unless sample

        [{ type: 'text', text: "The factory's own sample of #{value}#{" (measured color #{hex})" if hex}:" },
         image(Surfaces.rgb(Vips::Image.new_from_buffer(sample, '')))]
      end

      # The color a buyer is promised is the sample's, not whatever the name
      # suggests to the drawing model.
      def match_rule(sample, hex)
        return '' unless sample

        " The new finish must match the sample's color#{" (#{hex})" if hex} and pattern under the room's lighting. " \
          'A clearly different color or shade (cream or gray where the sample is bright white, dark wood where it is ' \
          'light, a different hue) is clearly wrong: score 2.'
      end

      def image(img)
        { type: 'image', source: { type: 'base64', media_type: 'image/jpeg',
                                   data: Base64.strict_encode64(img.thumbnail_image(1000).jpegsave_buffer(Q: 80)) } }
      end
    end
  end
end
