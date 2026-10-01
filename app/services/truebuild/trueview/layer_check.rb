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
      def judge(original_bytes, layer_bytes, surface:, value:)
        photo = Surfaces.rgb(Vips::Image.new_from_buffer(original_bytes, ''))
        layer = Vips::Image.new_from_buffer(layer_bytes, '')
        layer = Layer.fit(layer, photo.width, photo.height) if layer.width != photo.width || layer.height != photo.height
        composite = photo.composite2(layer, :over).extract_band(0, n: 3).cast(:uchar).copy(interpretation: :srgb)
        result = Catalog::PriceBooks::ClaudeClient.call(
          system: 'You check renderings for a home configurator before buyers see them. Judge only what a buyer would ' \
                  'notice looking at the second image.',
          tool: TOOL, max_tokens: 300, temperature: 0,
          content: [{ type: 'text', text: 'The photo as built:' }, image(photo),
                    { type: 'text', text: "The same photo with the #{surface} changed to #{value}. Is all of the visible " \
                                          "#{surface} in the new finish, evenly, with nothing else changed or added?" },
                    image(composite)]
        )
        score = result[:input]['score'].to_i
        { 'score' => score, 'note' => result[:input]['note'].to_s.strip.presence, 'ok' => score >= MIN_SCORE,
          'cost_usd' => Catalog::PriceBooks::ClaudeClient.cost_usd(result[:input_tokens], result[:output_tokens]).round(4) }
      rescue Catalog::PriceBooks::ClaudeClient::Error => e
        # The check could not run: show the layer rather than hide good work,
        # and say so in review.
        { 'score' => nil, 'note' => "Not checked: #{e.message.first(120)}", 'ok' => true, 'cost_usd' => 0 }
      end

      def image(img)
        { type: 'image', source: { type: 'base64', media_type: 'image/jpeg',
                                   data: Base64.strict_encode64(img.thumbnail_image(1000).jpegsave_buffer(Q: 80)) } }
      end
    end
  end
end
