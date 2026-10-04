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

    def refresh!(manufacturer, client_class: Scrapers::ChampionImsClient)
      variants = CatalogPlanVariant.where(manufacturer_id: manufacturer.id).includes(:catalog_plan).to_a
      by_champion_id = variants.group_by { |v| v.external_ids['champion_model_id'] }.except(nil)
      by_number = variants.group_by(&:model_number)
      linked = 0

      feed_homes(client_class).each do |home|
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
        end
        linked += matches.size
      end
      linked
    end

    def feed_homes(client_class)
      codes = (ChampionImsRetailer.distinct.pluck(:retailer_navision_id) + DEFAULT_RETAILERS).map(&:upcase).uniq
      codes.flat_map { |code| client_class.new(navision_id: code).fetch_all }.uniq { |h| h['id'] }
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
