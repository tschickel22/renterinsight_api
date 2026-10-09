# frozen_string_literal: true

module Truebuild
  # Photos of each catalog model from Champion's own site, so a buyer
  # designing a home sees the home: gallery shots tagged by room, elevations,
  # floor plans and the 3D tour.
  #
  # Champion's retailer feeds list the models a dealer sells, with Champion's
  # model id and photos whose file names often carry the factory model
  # number ("Prime-1676H32P01-Exterior"). A feed model links to our variants
  # by that model id, else by a model number in its photos when the series
  # agrees too: Champion's photos are sometimes labelled with another model's
  # number, and a number alone would hang the wrong kitchen on a home.
  module ModelMedia
    module_function

    # Retailer codes whose feeds are read: every Champion retailer a dealer
    # has connected, plus two active dealers' codes (Factory Direct Homes
    # Center and Heartland Homes) so the catalog has photos before any
    # dealer on this environment connects one.
    DEFAULT_RETAILERS = %w[2264IN 0551KS].freeze
    ROOMS = {
      'kitchen' => /kitchen|island|pantry/i, 'bath' => /bath|shower|vanity|lav\b/i, 'bedroom' => /bed ?room|primary|master|closet/i,
      'living' => /living|family|den|great ?room|fireplace/i, 'dining' => /dining/i, 'laundry' => /laundry|utility|mud/i,
      'exterior' => /exterior|front|porch|elevation|rendering/i
    }.freeze

    # catalog: fetches Champion's public catalog near a plant (catalog_page);
    # specs pass their own.
    def refresh!(manufacturer, client_class: Scrapers::ChampionImsClient, catalog: method(:catalog_page))
      variants = CatalogPlanVariant.where(manufacturer_id: manufacturer.id).includes(:catalog_plan).to_a
      by_champion_id = variants.group_by { |v| v.external_ids['champion_model_id'] }.except(nil)
      by_number = variants.group_by(&:model_number)
      linked = 0
      fed = {} # variant id => the feed's media, for its other sizes

      feed_homes(client_class, manufacturer, catalog).each do |home|
        matches = Array(by_champion_id[home['id']])
        matches |= numbers_in(home).flat_map { |n| Array(by_number[n]) }.select { |v| series_agrees?(v, home) }
        if matches.empty?
          same_series = variants.select { |v| series_agrees?(v, home) }
          matches = same_series.select { |v| name_agrees?(v, home) }
          # "Barkley Reverse Aisle" is Barkley mirrored: its photos fit.
          matches = same_series.select { |v| name_agrees?(v, home, prefix: true) } if matches.empty?
        end
        next if matches.empty?

        media = media_for(home, client_class)
        matches.each do |v|
          v.update_columns(media: v.media_from_feed(media), external_ids: v.external_ids.merge('champion_model_id' => v.external_ids['champion_model_id'] || home['id'],
                                                                            'champion_slug' => v.external_ids['champion_slug'] || home['slug']),
                           updated_at: Time.current)
          fed[v.id] = media
        end
        linked += matches.size
      end
      share_with_sizes!(variants, fed)
      linked
    end

    # Champion photographs one size of a plan. Its other sizes, its HUD and
    # modular builds (2856H32168, 2860H32168, 2860M32168: one plan, Bay Port)
    # and its reverse aisle ("Barkley Reverse Aisle" is Barkley mirrored) are
    # the same home, so they show its photos and floor plans: tagged
    # shared_from, and never over a model's own photos.
    def share_with_sizes!(variants, fed)
      return 0 if fed.empty?

      by_id = variants.index_by(&:id)
      shared = 0
      variants.each do |v|
        next if fed.key?(v.id)
        next if Array(v.media.to_h['photos']).any? && v.media.to_h['shared_from'].blank?

        source = fed.keys.map { |id| by_id[id] }.find { |src| same_home?(src, v) }
        next unless source

        v.update_columns(media: v.media_from_feed(fed[source.id].merge('shared_from' => source.model_number)), updated_at: Time.current)
        shared += 1
      end
      shared
    end

    def same_home?(source, variant)
      a = source.catalog_plan
      b = variant.catalog_plan
      return false unless a && b && a.series == b.series && a.factory_id == b.factory_id
      return true if a.id == b.id

      b.name.to_s.downcase.squish == "#{a.name.to_s.downcase.squish} reverse aisle"
    end

    # Retailers' feeds list only what those retailers stock; Champion's public
    # catalog lists every model a plant builds (most of a price book's models
    # have no retailer feed photos otherwise).
    def feed_homes(client_class, manufacturer = nil, catalog = method(:catalog_page))
      codes = (ChampionImsRetailer.distinct.pluck(:retailer_navision_id) + DEFAULT_RETAILERS).map(&:upcase).uniq
      ims = codes.flat_map { |code| client_class.new(navision_id: code).fetch_all }
      (ims + catalog_homes(manufacturer, ims, catalog)).uniq { |h| h['id'] }
    end

    # The catalog answers by distance from a place, so each plant is asked for
    # near its own town, under its brand, keeping only that plant's homes.
    # A plant's town and state come from the feeds' homes when not set.
    def catalog_homes(manufacturer, ims_homes, catalog)
      return [] unless manufacturer

      locate_factories!(manufacturer, ims_homes)
      # A plant builds under its own brand and the manufacturer's: Topeka
      # builds Dutch Housing's Aspire and Champion Homes' Genesis.
      manufacturer.factories.where.not(city: [nil, '']).where.not(state: [nil, '']).flat_map do |f|
        [f.brand, manufacturer.name].compact.map { |b| b.to_s.parameterize }.uniq.flat_map do |brand|
          Array(catalog.call(brand, "#{f.city}, #{f.state}"))
            .select { |h| h['factoryBrandCity'].to_s.casecmp?(f.city.to_s) && h['factoryBrandState'].to_s.casecmp?(f.state.to_s) }
        rescue StandardError => e
          Rails.logger.warn("[ModelMedia] Champion catalog near #{f.name} (#{brand}): #{e.message}")
          []
        end
      end
    end

    # "Topeka, Dutch Housing" is the Dutch Housing plant in the town a feed's
    # home names (factoryBrandCity Topeka, factoryBrandState IN).
    def locate_factories!(manufacturer, ims_homes)
      manufacturer.factories.select { |f| f.city.blank? || f.state.blank? }.each do |f|
        town = f.name.to_s.split(',').first.to_s.strip
        home = ims_homes.find do |h|
          h['factoryBrandCity'].to_s.casecmp?(town) && h['factoryBrandState'].present? &&
            h['factoryBrand'].to_s.downcase.include?(f.brand.to_s.downcase.split.first.to_s)
        end
        f.update_columns(city: home['factoryBrandCity'], state: home['factoryBrandState'], updated_at: Time.current) if home
      end
    end

    def catalog_page(brand_slug, location)
      uri = URI(Catalog::PriceBooks::LinkSources::CHAMPION_ENDPOINT)
      uri.query = URI.encode_www_form('Radius' => 150, 'BrandSlug' => brand_slug, 'Location' => location,
                                      'pagination-limit' => 500, 'pagination-page' => 1)
      Array(Catalog::PriceBooks::LinkSources.get_json(uri)['data'])
    end

    # Model numbers printed in the feed's photo file names.
    def numbers_in(home)
      Array(home['images']).flat_map { |i| "#{i['assetPath']} #{i['path']}".scan(/\d{4}\s*[HM]\s*\d\d[0-9A-Z]{3}/i) }
                           .map { |n| Catalog::ModelNumber.normalize(n) }.uniq
    end

    def series_agrees?(variant, home)
      words = variant.catalog_plan.series.to_s.downcase.split - %w[champion homes of the]
      text = "#{home['seriesName']} #{home['name']}".downcase
      words.any? { |w| text.match?(/\b#{Regexp.escape(w)}\b/) }
    end

    # "Aspire Winston" is our Aspire plan Winston; "Prime Grand 043" our Prime Grand.
    def name_agrees?(variant, home, prefix: false)
      series_words = variant.catalog_plan.series.to_s.downcase.split
      home_name = (home['name'].to_s.downcase.split - series_words).join(' ').gsub(/\b\d{3}\b/, '').squish
      plan_name = (variant.catalog_plan.name.to_s.downcase.split - series_words).join(' ').squish
      return false if plan_name.length < 3 || home_name.length < 3

      prefix ? plan_name.start_with?("#{home_name} ") : home_name == plan_name
    end

    def media_for(home, client_class)
      pdp = client_class.new(navision_id: DEFAULT_RETAILERS.first).fetch_pdp_media(home['slug'])
      feed_photos = Array(home['images']).map { |i| i['path'] }.compact
      gallery = (Array(pdp[:gallery]) + feed_photos).uniq
      {
        'source' => 'champion', 'slug' => home['slug'], 'name' => home['name'], 'plant' => home['factoryBrand'],
        'photos' => gallery.map { |url| { 'url' => url, 'room' => room_for(url) } },
        'elevations' => Array(pdp[:elevations]), 'floor_plans' => Array(pdp[:floor_plans]),
        'matterport_url' => pdp[:matterport_url], 'video_url' => pdp[:video_url], 'fetched_at' => Time.current.iso8601
      }.compact
    end

    def room_for(url)
      name = URI.decode_www_form_component(url.to_s.split('/').last.to_s) rescue url.to_s
      ROOMS.find { |_, pattern| name.match?(pattern) }&.first
    end
  end
end
