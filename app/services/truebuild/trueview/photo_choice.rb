# frozen_string_literal: true

module Truebuild
  module Trueview
    # Which of a model's photos TrueView draws on, per room. Photos come from
    # the factory's feeds, labelled kitchen, bath and so on from their file
    # names (ModelMedia), and the first with a label was not always the best:
    # a close-up of a sink, or the back of the house.
    #
    #   1. a platform admin's choice in Review a model (up to MAX per room)
    #   2. Claude's pick, made once per model from that room's photos
    #   3. the first photo with that room's label
    module PhotoChoice
      module_function

      ROOMS = %w[kitchen bath exterior].freeze
      MAX = 3
      CANDIDATES = 6 # photos per room shown to Claude

      # [[room, url], ...] in room order.
      def photos(variant)
        media = variant.media || {}
        ROOMS.flat_map { |room| chosen(media, room).map { |url| [room, url] } }
      end

      def chosen(media, room)
        picked = Array(media.dig('trueview_photos', room)).select { |u| candidate_urls(media, room, all: true).include?(u) }
        return picked.first(MAX) if picked.any?

        auto = media.dig('trueview_auto', room)
        return [auto] if auto.present? && candidate_urls(media, room).include?(auto)

        candidate_urls(media, room).first(1)
      end

      def source(media, room)
        if Array(media.dig('trueview_photos', room)).any? then 'chosen'
        elsif media.dig('trueview_auto', room).present? then 'picked'
        else 'first'
        end
      end

      # The room's labelled photos; all: every photo, for an admin who knows
      # an unlabelled one is the kitchen. Hidden photos are never drawn on.
      def candidate_urls(media, room, all: false)
        hidden = Array(media['hidden_photos'])
        list = Array(media['photos']).select { |p| p['url'].present? && hidden.exclude?(p['url']) }
        list = list.select { |p| p['room'] == room } unless all
        list.map { |p| p['url'] }.uniq
      end

      # Rooms where Claude should pick: several candidates, no admin choice,
      # no pick yet.
      def needs_pick?(variant)
        media = variant.media || {}
        ROOMS.any? do |room|
          Array(media.dig('trueview_photos', room)).empty? && media.dig('trueview_auto', room).blank? &&
            candidate_urls(media, room).size > 1
        end
      end

      PICK_TOOL = {
        name: 'pick_photo',
        description: 'Pick the photo that best shows the room for a buyer choosing finishes.',
        input_schema: { type: 'object', properties: { photo: { type: 'integer', description: 'The photo number.' },
                                                      reason: { type: 'string' } }, required: ['photo'] }
      }.freeze

      SHOWS = {
        'kitchen' => 'cabinets, countertops, backsplash and appliances',
        'bath' => 'the vanity cabinet, countertop, walls and floor',
        'exterior' => 'the front of the house: siding, roof, trim and windows'
      }.freeze

      # Claude picks each room's photo, once. Stored on the model's media.
      def pick!(variant)
        media = variant.media || {}
        auto = (media['trueview_auto'] || {}).dup
        ROOMS.each do |room|
          next if Array(media.dig('trueview_photos', room)).any? || auto[room].present?

          urls = candidate_urls(media, room).first(CANDIDATES)
          next if urls.empty?

          auto[room] = urls.size == 1 ? urls.first : picked_elsewhere(variant, room, urls) || ask(room, urls)
        end
        variant.update_columns(media: media.merge('trueview_auto' => auto.merge('picked_at' => Time.current.iso8601)))
      end

      # Two factories often carry the same model with the same photos: use the
      # pick already made for those photos rather than asking (and paying) again.
      def picked_elsewhere(variant, room, urls)
        CatalogPlanVariant.where.not(id: variant.id).where("media->'trueview_auto'->>? IN (?)", room, urls)
                          .first&.media&.dig('trueview_auto', room)
      end

      def ask(room, urls)
        content = urls.each_with_index.flat_map do |url, i|
          img = Vips::Image.new_from_buffer(Trueview.fetch_source(url)[:bytes], '').thumbnail_image(600)
          [{ type: 'text', text: "Photo #{i + 1}:" },
           { type: 'image', source: { type: 'base64', media_type: 'image/jpeg', data: Base64.strict_encode64(img.jpegsave_buffer(Q: 75)) } }]
        end
        content << { type: 'text', text: "These are #{room} photos of one manufactured home. Pick the one that shows the most of " \
                                         "#{SHOWS[room]}, from a natural viewpoint, well lit and not a close-up of one detail." }
        result = Catalog::PriceBooks::ClaudeClient.call(system: 'You choose photos for a home configurator.', tool: PICK_TOOL,
                                                        max_tokens: 200, temperature: 0, content: content)
        index = result[:input]['photo'].to_i - 1
        urls[index.between?(0, urls.size - 1) ? index : 0]
      rescue Catalog::PriceBooks::ClaudeClient::Error, Vips::Error, Trueview::Error
        urls.first
      end
    end
  end
end
