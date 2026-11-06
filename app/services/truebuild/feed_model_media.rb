# frozen_string_literal: true

module Truebuild
  # Model photos from a catalog source whose homes carry the price book's own
  # model number as their key: Clayton's SKUs ("47TRT14602DH") are both the
  # feed key and the number in the book. The source names the TrueBuild
  # plants it feeds (config factory_ids); the feed is read directly, so no
  # dealer has to carry the homes in inventory.
  #
  # Clayton files photos under ext/ and int/ only, with no room. TrueView draws
  # on kitchen, bath and exterior photos, so Claude labels each interior photo
  # once, from small thumbnails; a label is kept by URL and never paid twice.
  module FeedModelMedia
    module_function

    ROOMS = %w[kitchen bath living dining bedroom laundry exterior other].freeze
    BATCH = 16
    TAG_TOOL = {
      name: 'label_rooms',
      description: 'Say which room each numbered photo of a manufactured home shows.',
      input_schema: {
        type: 'object', required: ['photos'],
        properties: { photos: { type: 'array', items: { type: 'object', required: %w[photo room],
                                                         properties: { photo: { type: 'integer' }, room: { type: 'string', enum: ROOMS } } } } }
      }
    }.freeze

    def sources
      CatalogSource.active.select { |s| Array(s.config.to_h['factory_ids']).any? && s.adapter_type != 'cavco_plant' }
    end

    # @return [Hash] { linked:, unmatched: [model numbers], labelled: }
    def refresh!(source, tagger: method(:label_rooms))
      factory_ids = Array(source.config.to_h['factory_ids']).map(&:to_i)
      variants = CatalogPlanVariant.joins(:catalog_plan).where(catalog_plans: { factory_id: factory_ids }).to_a
      by_number = variants.group_by { |v| v.model_number.to_s.upcase }
      adapter = Catalog::AdapterRegistry.for(source)
      result = { linked: 0, unmatched: [], labelled: 0 }
      seen = Set.new

      adapter.discover.each do |key|
        home = adapter.parse(adapter.fetch(key))
        next unless home

        number = Catalog::ModelNumber.normalize(home.source_key.to_s)
        matches = Array(by_number[number])
        next if matches.empty?

        seen << number
        matches.each do |v|
          media = media_for(home, v.media || {}, tagger, result)
          v.update_columns(media: v.media_from_feed(media), external_ids: v.external_ids.merge('feed_key' => home.source_key), updated_at: Time.current)
          result[:linked] += 1
        end
      end
      result[:unmatched] = by_number.keys - seen.to_a
      result
    end

    def media_for(home, previous, tagger, result)
      known = Array(previous['photos']).to_h { |p| [p['url'], p['room']] }
      shots, plans = Array(home.images).partition { |i| !i['is_floorplan'] }
      photos = shots.filter_map { |i| i['source_url'].presence }.uniq.map do |url|
        { 'url' => url, 'room' => known[url] || room_from_name(url) }
      end
      unlabelled = photos.select { |p| p['room'].nil? }.map { |p| p['url'] }
      if unlabelled.any?
        labels = tagger.call(unlabelled)
        result[:labelled] += labels.size
        photos.each { |p| p['room'] ||= labels[p['url']] }
      end
      {
        'source' => 'feed', 'name' => home.model_name, 'feed_key' => home.source_key,
        'photos' => photos.map(&:compact),
        'floor_plans' => plans.filter_map { |i| i['source_url'].presence }.uniq,
        'matterport_url' => home.virtual_tour_url, 'video_url' => home.video_url,
        'fetched_at' => Time.current.iso8601
      }.compact
    end

    # A room in the file name or folder ("/ext/", "kitchen_002"); nil when it
    # says nothing.
    def room_from_name(url)
      return 'exterior' if url.to_s.match?(%r{/ext/}i)

      CavcoModelMedia.room_for(url)
    end

    # { url => room } for photos Claude could read; the rest stay unlabelled.
    def label_rooms(urls)
      urls.each_slice(BATCH).each_with_object({}) do |batch, out|
        content = []
        kept = []
        batch.each do |url|
          img = Vips::Image.new_from_buffer(Trueview.fetch_source(url)[:bytes], '').thumbnail_image(400)
          kept << url
          content << { type: 'text', text: "Photo #{kept.size}:" }
          content << { type: 'image', source: { type: 'base64', media_type: 'image/jpeg', data: Base64.strict_encode64(img.jpegsave_buffer(Q: 70)) } }
        rescue Vips::Error, Trueview::Error => e
          Rails.logger.warn("[FeedModelMedia] #{url}: #{e.message}")
        end
        next if kept.empty?

        content << { type: 'text', text: 'Label the room each photo shows. A kitchen photo shows cabinets and counters; ' \
                                         'a bath photo shows a vanity, tub or shower. Use other for hallways, closets and details.' }
        r = Catalog::PriceBooks::ClaudeClient.call(system: 'You sort photos of manufactured homes by room.', tool: TAG_TOOL,
                                                   max_tokens: 1500, temperature: 0, content: content)
        Array(r[:input]['photos']).each do |p|
          url = kept[p['photo'].to_i - 1]
          # 'other' is kept too, so a hallway is not sent to be read again.
          out[url] = p['room'] if url && ROOMS.include?(p['room'])
        end
      rescue Catalog::PriceBooks::ClaudeClient::Error => e
        Rails.logger.warn("[FeedModelMedia] labelling failed: #{e.message}")
      end
    end
  end
end
