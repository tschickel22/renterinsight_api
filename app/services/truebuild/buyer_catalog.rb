# frozen_string_literal: true

module Truebuild
  # What a buyer on a dealer's website may see for one model: the options it
  # can have, grouped the way a buyer chooses (one color per set), standard
  # features, and retail prices only when the dealer shows prices. Never cost.
  class BuyerCatalog
    SHOWS_PRICES = %w[full starting_at].freeze
    SHOWS_MONTHLY = %w[full starting_at monthly].freeze

    # A dealer offers TrueBuild once they have set up pricing, and only on
    # models a published book covers.
    def self.available?(company, variant)
      return false unless variant && BookResolver.current_for(variant)

      company.dealer_markup_rules.active.exists? || company.dealer_catalog_terms.exists?
    end

    def initialize(company, variant, location: nil, vehicle: nil)
      @company = company
      @variant = variant
      @vehicle = vehicle
      @location = location || vehicle&.location
      @terms = DealerCatalogTerm.effective(company, variant.manufacturer_id)
      @book = BookResolver.current_for(variant)
    end

    # Pricing every option on a model takes a second or two, so the priced
    # catalog is cached per dealer, model and location until their prices
    # can have moved. Photos are added fresh (the lot home's own come first).
    def call
      Rails.cache.fetch(cache_key, expires_in: 30.minutes) { build }.merge(media: media)
    end

    # What the buyer's designer shows: the dealer's buyer view applied
    # (BuyerView). Everything else (pricing, saving, TrueView) reads the
    # full catalog.
    def for_buyer
      full = call
      full.merge(groups: BuyerView.apply(full[:groups], @terms))
    end

    def build
      offered = offered_prices
      engine = PricingEngine.new(company: @company, variant: @variant, location: @location,
                                 option_ids: offered.map(&:catalog_option_id).uniq).call
      retail_by_option = engine.lines.select { |l| l[:kind] == 'option' }.to_h { |l| [l[:option_id], l[:retail]] }
      starting = self.class.starting_retail(engine.lines)
      show = SHOWS_PRICES.include?(@terms.price_display) && starting.present?
      monthly = SHOWS_MONTHLY.include?(@terms.price_display) && starting.present? && payments.enabled?

      {
        variant: variant_json,
        display: { mode: @terms.price_display, show_prices: show, show_monthly: monthly,
                   payment_terms: (payments.terms if monthly) },
        base_price: show ? starting : nil,
        base_monthly: monthly ? payments.monthly(starting) : nil,
        groups: groups(offered, show ? retail_by_option : {}),
        standard_features: standard_features,
        # The dealer's own: always in the price (delivery, setup), or the buyer's
        # choice. Quote-only ones never reach a buyer.
        addons: {
          included: dealer_addons.select { |a| a.mode == 'included' }.map { |a| addon_json(a, show) },
          optional: dealer_addons.select { |a| a.mode == 'optional' }.map { |a| addon_json(a, show) }
        }
      }
    end

    # The home on the lot first, then the manufacturer's photos of the model.
    def media
      m = @variant.media || {}
      lot = Array(@vehicle&.public_image_urls).compact.map { |url| { url: url, room: nil, lot: true } }
      photos = lot + Array(m['photos']).map { |p| { url: p['url'], room: p['room'] } }
      { photos: photos.uniq { |p| p[:url] }.first(60), floor_plans: Array(m['floor_plans']).first(4),
        elevations: Array(m['elevations']).first(6), tour_url: m['matterport_url'], video_url: m['video_url'] }
    end

    # Retail total for a selection, or nil when the dealer hides prices.
    def price(option_ids, addon_ids = [])
      result = PricingEngine.new(company: @company, variant: @variant, location: @location,
                                 option_ids: allowed(option_ids), addon_ids: allowed_addons(addon_ids)).call
      show = SHOWS_PRICES.include?(@terms.price_display) && result.totals[:retail].present?
      monthly = SHOWS_MONTHLY.include?(@terms.price_display) && result.totals[:retail].present? && payments.enabled?
      { show_prices: show, total: show ? result.totals[:retail] : nil,
        monthly: monthly ? payments.monthly(result.totals[:retail]) : nil,
        lines: show ? result.retail_only[:lines] : [], book_id: result.book&.id, option_ids: allowed(option_ids),
        addon_ids: allowed_addons(addon_ids) }
    end

    # The price before any choices: the home plus what is always in it
    # (freight, the dealer's included add-ons like delivery and setup).
    def self.starting_retail(lines)
      always = lines.reject { |l| l[:kind] == 'option' }
      return nil if always.empty? || always.any? { |l| l[:retail].nil? }

      always.sum { |l| l[:retail].to_d }.to_f
    end

    # Only this dealer's optional add-ons; included ones are always priced.
    def allowed_addons(addon_ids)
      Array(addon_ids).map(&:to_i).uniq & dealer_addons.select { |a| a.mode == 'optional' }.map(&:id)
    end

    # Only options this model offers; anything else from the client is dropped.
    def allowed(option_ids)
      ids = Array(option_ids).map(&:to_i).uniq
      ids & offered_prices.map(&:catalog_option_id)
    end

    private

    def payments
      @payments ||= PaymentEstimate.new(@company)
    end

    def dealer_addons
      @dealer_addons ||= @company.truebuild_addons.active.for_manufacturer(@variant.manufacturer_id)
                                 .where.not(mode: 'quote_only').includes(:source).order(:position, :id).to_a
    end

    def addon_json(addon, show)
      { id: addon.id, name: addon.name, description: addon.description.presence, price: show ? addon.price.to_f : nil }
    end

    def cache_key
      stamp = [@company.dealer_markup_rules.maximum(:updated_at), @company.dealer_catalog_terms.maximum(:updated_at),
               @company.truebuild_addons.maximum(:updated_at),
               @company.dealer_price_book_adoptions.maximum(:updated_at), CatalogPriceBook.published.maximum(:published_at),
               CatalogOption.where(manufacturer_id: @variant.manufacturer_id).maximum(:updated_at),
               CatalogSwatch.where(manufacturer_id: @variant.manufacturer_id).maximum(:updated_at),
               @variant.updated_at, @company.updated_at].map { |t| t&.to_i }.join('-')
      "truebuild:catalog:v6:#{@company.id}:#{@variant.id}:#{@location&.id}:#{stamp}"
    end

    def offered_prices
      @offered_prices ||= @book.option_prices.includes(option: :group).to_a
                               .select { |op| op.applies_to?(@variant) && op.option.status == 'active' }
    end

    def variant_json
      plan = @variant.catalog_plan
      { id: @variant.id, model_number: @variant.model_number, name: plan.name, series: plan.series,
        manufacturer: @variant.manufacturer&.name, building_code: @variant.building_code,
        beds: @variant.beds, baths: @variant.baths&.to_f, width_ft: @variant.width_ft, length_ft: @variant.length_ft }
    end

    # Options by group. Colors form one-of-a-kind choice sets; everything else
    # is an add-on the buyer ticks. A standard option is shown as included.
    # "Shutters: Black" as a no-charge option is a color choice written as an
    # option: one of a set the buyer picks from, not something included.
    NAMED_CHOICE = /\A([A-Za-z0-9][A-Za-z0-9 ]{2,30}):\s*(.+)\z/ # "3 Tab Shingles: Black Weatherwood"

    def groups(prices, retail)
      uniq = prices.uniq(&:catalog_option_id)
      choices, rest = uniq.partition { |op| op.is_standard && op.option.kind != 'color' && op.option.name.match?(NAMED_CHOICE) }
      by_group = rest.group_by { |op| op.option.group }
      extra_sets = Hash.new { |h, k| h[k] = [] } # group id => [[set, option json]]
      choices.each do |op|
        set_title, value = op.option.name.match(NAMED_CHOICE).captures
        # Filed under the group its set belongs to (Shutters under Exterior),
        # else left in the group it came in.
        name = Catalog::PriceBooks::Sections.group_for(set_title).last
        group = by_group.keys.find { |g| g.name == name } ||
                CatalogOptionGroup.find_by(manufacturer_id: @variant.manufacturer_id, name: name) || op.option.group
        by_group[group] ||= []
        extra_sets[group.id] << [Catalog::PriceBooks::ColorSets.normalize(set_title),
                                 color_json(op, retail, set_title, value.strip)]
      end

      # Families span groups: order forms file a fireplace under Fireplaces
      # in one series and Interior Walls & Trim in another.
      families = OptionFamilies.for(rest.reject { |op| op.option.kind == 'color' }.map(&:option))
      by_group.sort_by { |g, _| [g.position.to_i, g.name] }.map do |group, ops|
        colors, others = ops.partition { |op| op.option.kind == 'color' }
        sets = colors.group_by { |op| op.option.metadata['color_set'].presence || 'Colors' }
                     .to_h { |set, cs| [set, cs.map { |op| color_json(op, retail, set) }] }
        extra_sets[group.id].each { |set, json| (sets[set] ||= []) << json }
        {
          id: group.id, name: group.name,
          color_sets: sets.map { |set, os| { name: set, options: os.uniq { |o| o[:name].downcase }.sort_by { |o| o[:name] } } }
                          .sort_by { |st| st[:name] },
          # A family's members sit together, under the first one's name.
          options: others.map { |op| option_json(op, retail).merge(family: families[op.catalog_option_id]) }
                         .sort_by { |o| [o[:standard] ? 0 : 1, (o[:family] || o[:name]).downcase, o[:name].downcase] }
        }
      end.reject { |g| g[:color_sets].empty? && g[:options].empty? }
    end

    # A color chip: the factory's own sample picture and measured color when a
    # decor sheet has one, else a color guessed from the name.
    def color_json(op, retail, set, value = nil)
      name = value || op.option.name
      sample = CatalogSwatch.for_finish(manufacturer_id: @variant.manufacturer_id, factory_id: @variant.catalog_plan&.factory_id,
                                        surface: set, value: name, pool: samples)
      option_json(op, retail).merge(name: name, kind: 'color', hex: sample&.hex || ColorSwatches.hex(name),
                                    swatch_url: op.option.swatch_url.presence || sample&.image_url)
    end

    def samples
      @samples ||= CatalogSwatch.where(manufacturer_id: @variant.manufacturer_id,
                                       factory_id: [@variant.catalog_plan&.factory_id, nil].uniq).to_a
    end

    def option_json(op, retail)
      o = op.option
      { id: o.id, name: o.name, kind: o.kind, standard: op.is_standard, swatch_url: o.swatch_url,
        hex: (ColorSwatches.hex(o.name) if o.kind == 'color'),
        in_place_of: o.in_place_of, price: op.is_standard ? nil : retail[o.id] }
    end

    # Standards sheets are titled by product line, not plan series ("Dutch
    # Aspire Sectionals", "Genesis Homes"): take the sheets naming this
    # series, then the one for this home's construction.
    def standard_features
      words = @variant.catalog_plan.series.to_s.downcase.split - %w[champion homes of the]
      sheets = @book.standard_features.distinct.pluck(:series).select do |s|
        s.nil? || words.any? { |w| s.downcase.match?(/\b#{Regexp.escape(w)}\b/) }
      end
      sheet = best_sheet(sheets.compact)
      @book.standard_features.where(series: [nil, sheet].uniq).where(building_code: [nil, @variant.building_code])
           .order(:category, :position)
           .group_by(&:category).map { |cat, fs| { category: cat, items: fs.map(&:name).uniq } }
    end

    def best_sheet(sheets)
      return sheets.first if sheets.size <= 1

      want = if @variant.building_code == 'MOD' then /modular/i
             elsif @variant.width_ft.to_i > 18 then /sectional|multi|double/i
             else /single/i
             end
      sheets.find { |s| s.match?(want) } || sheets.reject { |s| s.match?(/modular|sectional|multi|double|single/i) }.first
    end
  end
end
