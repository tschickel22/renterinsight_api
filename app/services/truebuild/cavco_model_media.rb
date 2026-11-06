# frozen_string_literal: true

module Truebuild
  # Photos of each Cavco model from Cavco's own index, so a buyer designing a
  # home sees it and TrueView has rooms to draw on. The Cavco counterpart of
  # ModelMedia (Champion).
  #
  # Each cavco_plant CatalogSource names the plant it reads (config plant.id)
  # and the TrueBuild plant it feeds (config factory_id). Cavco reuses one
  # footprint number across series (Plant City's 15763A is Cavco Select,
  # Craft Select and Elite Tommie), so a number links only when the name or
  # series agrees, unless it is the only model with that number on both
  # sides. A model Cavco publishes with no number (the Anthem duplexes,
  # "Duplex") links by name.
  #
  # Rooms come from the photo's file name ("..._kitchen_002_web_...",
  # "..._kit_0319_...", "..._exterior_001_render_..."). The alt text is no
  # help: it says "3 bedroom, 2 bathroom" on every photo.
  module CavcoModelMedia
    module_function

    ROOMS = [
      ['kitchen', /(?:\A|_)(?:kitchen|kit|island|pantry)(?:_|\z)/],
      ['bath', /(?:\A|_)(?:bath|bathroom|primarybath|masterbath|shower|vanity|lav)(?:_|\z)/],
      ['exterior', /(?:\A|_)(?:exterior|ext|rf\d|front|elevation|render|porch)(?:_|\z)/],
      ['living', /(?:\A|_)(?:living|livingroom|liv|den|family|familyroom|greatroom)(?:_|\z)/],
      ['dining', /(?:\A|_)(?:dining|diningroom)(?:_|\z)/],
      ['bedroom', /(?:\A|_)(?:bed|bedroom|bunks|primary|master|closet)(?:_|\z)/],
      ['laundry', /(?:\A|_)(?:laundry|utility)(?:_|\z)/]
    ].freeze
    NUMBER = /\A\d{5}[A-Z0-9]\z/
    GENERIC = %w[the ii iii iv vi duplex series cottages loft].freeze

    # @return [Hash] { linked:, unmatched: [model numbers] } per run
    def refresh!(manufacturer)
      result = { linked: 0, unmatched: [] }
      CatalogSource.active.where(adapter_type: 'cavco_plant').find_each do |source|
        factory_id = source.config.to_h['factory_id']
        next unless factory_id && Factory.where(id: factory_id, manufacturer_id: manufacturer.id).exists?

        docs = floorplans(source)
        next if docs.empty?

        variants = CatalogPlanVariant.joins(:catalog_plan).where(catalog_plans: { factory_id: factory_id })
                                     .includes(:catalog_plan).to_a
        variants.each do |v|
          doc = match(v, docs, variants)
          next result[:unmatched] << v.model_number unless doc

          media = media_for(doc)
          next result[:unmatched] << v.model_number if media['photos'].empty? && media['floor_plans'].empty?

          v.update_columns(media: v.media_from_feed(media),
                           external_ids: v.external_ids.merge('cavco_floorplan_id' => doc['id']), updated_at: Time.current)
          result[:linked] += 1
        end
      end
      result
    end

    def floorplans(source)
      adapter = Catalog::AdapterRegistry.for(source)
      adapter.discover.filter_map { |key| adapter.fetch(key) }
    end

    def match(variant, docs, variants)
      number = variant.model_number.to_s.upcase
      if number.match?(NUMBER)
        same = docs.select { |d| number_of(d) == number }
        # The closest name wins: Craft Select 15763A shares "select" with
        # Cavco Select 15763A but both words with Craft Select.
        scored = same.map { |d| [d, agreement(variant, d)] }.select { |_, n| n.positive? }
        best = scored.map(&:last).max
        top = scored.select { |_, n| n == best }.map(&:first)
        return top.first if top.size == 1
        return nil if top.size > 1

        # One model each side with this number: the number alone is enough.
        sharing = variants.count { |o| o.model_number.to_s.upcase == number }
        same.size == 1 && sharing == 1 ? same.first : nil
      else
        named = docs.select { |d| number_of(d).nil? && name_words(d['name']).intersect?(name_words(plan_name(variant))) }
        named.size == 1 ? named.first : nil
      end
    end

    # Words the names and series share: "Ashley" is Elite's Ashley 28603A,
    # not Craft Select 28603A.
    def agreement(variant, doc)
      ours = name_words(plan_name(variant)) | name_words(variant.catalog_plan&.series)
      theirs = name_words(doc['name']) | name_words(doc['series'])
      (ours & theirs).size
    end

    # Cavco writes some numbers with words in front ("1 Bedroom 13431S").
    def number_of(doc) = doc['model_number'].to_s.upcase[/\d{5}[A-Z0-9]\z/]

    # A plan name ending in its model number loses it; a name-keyed model
    # (Cumberland, number CUMBERLAND) keeps its name.
    def plan_name(variant)
      name = variant.catalog_plan&.name.to_s
      number = variant.model_number.to_s
      number.match?(NUMBER) ? name.sub(/\s*#{Regexp.escape(number)}\z/i, '') : name
    end

    def name_words(text)
      text.to_s.downcase.scan(/[a-z]+/).reject { |w| w.size < 3 || GENERIC.include?(w) }.to_set
    end

    def media_for(doc)
      photos = decode(doc['photos']).filter_map { |p| p['url'].presence }.uniq
      {
        'source' => 'cavco', 'cavco_id' => doc['id'], 'name' => [doc['name'], doc['model_number']].compact.join(' '),
        'series' => doc['series'],
        'photos' => photos.map { |url| { 'url' => url, 'room' => room_for(url) }.compact },
        'floor_plans' => decode(doc['line_drawings']).filter_map { |p| p['url'].presence }.uniq,
        'matterport_url' => doc['3d_tour'].to_s.match?(Catalog::Adapters::CavcoRetailerAdapter::TOUR_RE) ? doc['3d_tour'] : nil,
        'video_url' => doc['video_tour'].presence,
        'fetched_at' => Time.current.iso8601
      }.compact
    end

    def room_for(url)
      name = url.to_s.split('/').last.to_s.downcase.sub(/\.[a-z]+\z/, '').tr('-', '_')
      ROOMS.find { |_, pattern| name.match?(pattern) }&.first
    end

    def decode(value)
      list = value.is_a?(String) ? (JSON.parse(value) rescue []) : Array(value)
      list.select { |v| v.is_a?(Hash) }
    end
  end
end
