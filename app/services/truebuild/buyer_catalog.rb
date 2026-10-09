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
    MODULE = 'sales.configurator' # TrueBuild Home Designer on the dealer's plan

    def self.available?(company, variant)
      return false unless variant && BookResolver.current_for(variant)
      return false unless company.has_module?(MODULE)
      return false unless company.dealer_markup_rules.active.exists? || company.dealer_catalog_terms.exists?

      # Only factories a platform admin gave this dealer, while released (E64).
      DealerFactories.offered?(company, variant)
    end

    # A home on the lot can be designed only while it is not built yet: a
    # model to order, or one ordered and on its way. Built homes in stock are
    # sold as they stand.
    DESIGNABLE_STATUSES = %w[available_to_order ordered on_order].freeze

    # The lot's homes a buyer can design, for listings and their filter:
    # not built yet, linked to a model a published book prices, with its
    # TrueView drawn, and the dealer offers TrueBuild. A home still waiting
    # on its drawings is listed like any other: 32 of one lot's homes said
    # Design it with finishes drawn on two.
    def self.designable_homes(company, vehicles)
      return vehicles.none unless company.has_module?(MODULE) &&
                                  (company.dealer_markup_rules.active.exists? || company.dealer_catalog_terms.exists?)

      linked = vehicles.where(status: DESIGNABLE_STATUSES)
                       .where(catalog_plan_variant_id: CatalogVariantPrice.where(catalog_price_book_id: CatalogPriceBook.published.select(:id))
                                                                          .select(:catalog_plan_variant_id))
      offered = DealerFactories.offered_variant_ids(company, linked.distinct.pluck(:catalog_plan_variant_id))
      ready = ModelList.trueview_ready(offered)
      linked.where(catalog_plan_variant_id: ready.to_a)
    end

    def self.designable_home?(company, vehicle)
      vehicle.present? && available?(company, vehicle.catalog_plan_variant) &&
        designable_homes(company, company.vehicles.where(id: vehicle.id)).exists?
    end

    # show_prices: a platform admin's preview (PreviewPass) checks the prices
    # whatever the dealer shows buyers. Cached apart from the buyer's catalog.
    def initialize(company, variant, location: nil, vehicle: nil, show_prices: false)
      @show_prices = show_prices
      @company = company
      @variant = variant
      @vehicle = vehicle
      @location = location || vehicle&.location
      @terms = DealerCatalogTerm.effective(company, variant.manufacturer_id)
      @book = BookResolver.current_for(variant)
      @options_book = OptionSource.current_for(variant)
    end

    # Pricing every option on a model takes a second or two, so the priced
    # catalog is cached per dealer, model and location until their prices
    # can have moved. Photos are added fresh (the lot home's own come first).
    def call
      CatalogOptionReviewJob.once(@options_book)
      Rails.cache.fetch(cache_key, expires_in: 30.minutes) { build }.merge(media: media)
    end

    # What the buyer's designer shows: the dealer's buyer view applied
    # (BuyerView). Everything else (pricing, saving, TrueView) reads the
    # full catalog.
    def for_buyer
      full = call
      full.merge(groups: without_failed_drawings(BuyerView.apply(full[:groups], @terms)))
    end

    # A finish whose TrueView drawing failed its check is not offered: a
    # buyer shown Destin White in the wrong color, or a note that it cannot
    # be shown, has been shown something wrong. A rep still quotes it. A set
    # is never emptied this way; the buyer still needs a color to pick.
    # A color no photo shows is not offered at all: shutter colors for a
    # home photographed without shutters, and then not "None" alone either.
    # Paid upgrades stay; a kitchen photo without the fridge does not mean
    # the fridge upgrade is not real.
    UNSEEN_MEANS_ABSENT = %w[shutters].freeze

    def without_failed_drawings(groups)
      held = Trueview::Buyer.held_back(@company, @variant)
      failed = held[:failed]
      gone = held[:not_pictured]
      return groups if failed.empty? && gone.empty?

      groups.map do |g|
        sets = g[:color_sets].filter_map do |st|
          # Only where the photo settles it: an exterior photo shows the whole
          # front, so no shutters there means the home has none. An interior
          # photo with a plain wall says nothing: Bay Port's kitchen shows no
          # tile, yet its book includes a 1 row backsplash, and hiding the set
          # left the buyer no way to choose its color.
          unseen = UNSEEN_MEANS_ABSENT.include?(Trueview::Surfaces.category(st[:name])) ? gone : Set.new
          shown = st[:options].reject { |o| unseen.include?(o[:id]) }
          next nil if shown.size < st[:options].size && shown.all? { |o| o[:name].to_s.match?(Trueview::Buyer::NOTHING) }

          kept = shown.reject { |o| failed.include?(o[:id]) }
          st.merge(options: kept.empty? ? shown : kept)
        end
        g.merge(color_sets: sets, options: g[:options].reject { |o| failed.include?(o[:id]) })
      end.reject { |g| g[:color_sets].empty? && g[:options].empty? }
    end

    # Every option group a model's price book offers, with no dealer and no
    # prices: what TrueView draws, once for every dealer who sells the model.
    def self.finish_groups(variant)
      book = OptionSource.current_for(variant)
      return [] unless book

      stamp = [book.id, book.updated_at, CatalogOption.where(manufacturer_id: variant.manufacturer_id).maximum(:updated_at),
               CatalogSwatch.where(manufacturer_id: variant.manufacturer_id).maximum(:updated_at),
               CatalogOptionDecision.stamp(variant.manufacturer_id), variant.updated_at].map { |t| t.try(:to_i) || t }
      Rails.cache.fetch("truebuild:finish_groups:v7:#{variant.id}:#{stamp.join('-')}", expires_in: 12.hours) do
        catalog = allocate
        catalog.instance_variable_set(:@variant, variant)
        catalog.instance_variable_set(:@options_book, book)
        catalog.finish_groups
      end
    end

    def finish_groups
      groups(offered_prices, {})
    end

    def build
      offered = offered_prices
      engine = PricingEngine.new(company: @company, variant: @variant, location: @location,
                                 option_ids: offered.map(&:catalog_option_id).uniq).call
      retail_by_option = engine.lines.select { |l| l[:kind] == 'option' }.to_h { |l| [l[:option_id], l[:retail]] }
      starting = self.class.starting_retail(engine.lines)
      show = prices_shown? && starting.present?
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
      m = @variant.shown_media
      lot = Array(@vehicle&.public_image_urls).compact.map { |url| { url: url, room: nil, lot: true } }
      photos = lot + Array(m['photos']).map { |p| { url: p['url'], room: p['room'] } }
      { photos: photos.uniq { |p| p[:url] }.first(60), floor_plans: Array(m['floor_plans']).first(4),
        elevations: Array(m['elevations']).first(6), tour_url: m['matterport_url'], video_url: m['video_url'] }
    end

    # Retail total for a selection, or nil when the dealer hides prices.
    def price(option_ids, addon_ids = [])
      result = PricingEngine.new(company: @company, variant: @variant, location: @location,
                                 option_ids: allowed(option_ids), addon_ids: allowed_addons(addon_ids)).call
      show = prices_shown? && result.totals[:retail].present?
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

    def prices_shown? = @show_prices || SHOWS_PRICES.include?(@terms.price_display)

    def addon_json(addon, show)
      { id: addon.id, name: addon.name, description: addon.description.presence, price: show ? addon.price.to_f : nil }
    end

    def cache_key
      stamp = [@company.dealer_markup_rules.maximum(:updated_at), @company.dealer_catalog_terms.maximum(:updated_at),
               @company.truebuild_addons.maximum(:updated_at),
               @company.dealer_price_book_adoptions.maximum(:updated_at), CatalogPriceBook.published.maximum(:published_at),
               CatalogOption.where(manufacturer_id: @variant.manufacturer_id).maximum(:updated_at),
               CatalogSwatch.where(manufacturer_id: @variant.manufacturer_id).maximum(:updated_at),
               CatalogOptionDecision.stamp(@variant.manufacturer_id),
               @variant.updated_at, @company.updated_at].map { |t| t&.to_i }.join('-')
      "truebuild:catalog:v15:#{@company.id}:#{@variant.id}:#{@location&.id}:#{stamp}#{':preview' if @show_prices}"
    end

    def offered_prices
      @offered_prices ||= OptionSource.offered(@options_book, @variant).select { |op| op.option.status == 'active' }
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
    # Sheet vinyl (lino) colors listed as standard items with the mill's
    # number: "Thunder (9661)", "Nordic White (9662)". The kitchen and bath
    # floor, a color the buyer chooses, not something merely included.
    FLOOR_COLOR = /\A[A-Za-z][A-Za-z ]+\s\(\d{4}\)\z/

    def groups(prices, retail)
      uniq = prices.uniq(&:catalog_option_id)
      @finish_alias = uniq.filter_map { |op| (v = decided(op, 'same_finish')) && [op.catalog_option_id, v] }.to_h
      floors, uniq = uniq.partition do |op|
        op.is_standard && op.option.kind != 'color' &&
          (decided(op, 'color_choice') ||
           (op.option.kind == 'standard' && op.option.name.match?(FLOOR_COLOR) && op.option.group&.name.to_s.match?(/floor/i)))
      end
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

      floors.each do |op|
        set = decided(op, 'color_choice') || 'Flooring'
        by_group[op.option.group] ||= []
        extra_sets[op.option.group.id] << [set, color_json(op, retail, set)]
      end

      # Families span groups: order forms file a fireplace under Fireplaces
      # in one series and Interior Walls & Trim in another.
      families = with_decisions(OptionFamilies.for(rest.reject { |op| op.option.kind == 'color' }.map(&:option)), rest)
      by_group = one_place_per_family(by_group, families)
      built = by_group.sort_by { |g, _| [g.name == FIRST_GROUP ? 0 : 1, g.position.to_i, g.name] }.map do |group, ops|
        colors, others = ops.partition { |op| op.option.kind == 'color' }
        sets = colors.group_by { |op| op.option.metadata['color_set'].presence || 'Colors' }
                     .to_h { |set, cs| [set, cs.map { |op| color_json(op, retail, set) }] }
        extra_sets[group.id].each { |set, json| (sets[set] ||= []) << json }
        [group, sets, others]
      end
      one_place_per_color_set(built).map do |group, sets, others|
        {
          id: group.id, name: group.name,
          color_sets: sets.map { |set, os| { name: set, options: one_per_finish(os).sort_by { |o| o[:name] } } }
                          .sort_by { |st| st[:name] },
          # A family's members sit together, under the first one's name.
          options: others.map { |op| option_json(op, retail).merge(family: families[op.catalog_option_id], learned: decided(op, 'family').present?) }
                         .sort_by { |o| [o[:standard] ? 0 : 1, (o[:family] || o[:name]).downcase, o[:name].downcase] }
        }
      end.reject { |g| g[:color_sets].empty? && g[:options].empty? }
    end

    # Cabinets lead the designer: the choice that sets the look of the
    # kitchen and baths.
    FIRST_GROUP = 'Cabinets'

    # A color set is one choice, so it is shown in one place: the group named
    # for it (Cabinets under Cabinets), else the first group holding it. Bay
    # Port's book lists Destin White and Timberwolf under Packages and under
    # Cabinets, and the buyer picked a cabinet color twice; Aspire 082's book
    # lists them only under Packages, so a buyer looking at Cabinets found
    # just the paid upgrades.
    # built: [[group, { set name => [chip] }, other ops]] in display order.
    def one_place_per_color_set(built)
      holders = Hash.new { |h, k| h[k] = [] }
      built.each { |group, sets, _| sets.each_key { |set| holders[set] << group } }
      holders.each do |set, groups|
        named = Catalog::PriceBooks::Sections.group_for(set).last
        home = groups.find { |g| g.name == named } || built.find { |g, _, _| g.name == named }&.first ||
               (@variant && CatalogOptionGroup.find_by(manufacturer_id: @variant.manufacturer_id, name: named)) || groups.first
        built << [home, {}, []] unless built.any? { |g, _, _| g == home }
        home_sets = built.find { |g, _, _| g == home }[1]
        groups.each do |g|
          next if g == home

          from = built.find { |b, _, _| b == g }[1]
          home_sets[set] = Array(home_sets[set]) + from.delete(set)
        end
      end
      built.sort_by { |g, _, _| [g.name == FIRST_GROUP ? 0 : 1, g.position.to_i, g.name] }
    end

    # A family is one choice, so it is shown in one place: the group holding
    # most of it. Bay Port's appliance packages came in three (Packages,
    # Kitchen & Appliances, and Backsplash & Tile for the black stainless
    # pair), and the buyer was asked to choose appliances three times.
    def one_place_per_family(by_group, families)
      homes = by_group.flat_map { |g, ops| ops.filter_map { |op| (f = families[op.catalog_option_id]) && [f, g] } }
                      .group_by(&:first)
                      .transform_values { |pairs| pairs.map(&:last).tally.max_by { |g, n| [n, -g.position.to_i] }.first }
      moved = Hash.new { |h, k| h[k] = [] }
      by_group.each do |g, ops|
        ops.each { |op| moved[(f = families[op.catalog_option_id]) ? homes[f] : g] << op }
        moved[g] # a group keeps its place even when all it held moved away
      end
      moved
    end

    # The same finish under two spellings is one chip. Bay Port's book names
    # each backsplash tile twice ("1 Row Ceramic Inhale Gris" and "1 Row
    # Inhale Gris (ceramic)", "2 Rows Catch Ice (subway)"), so the buyer saw
    # ten tiles for five. Same words in any order, with the tile's material
    # left out, is the same finish. Kept: an included one, then one with the
    # factory's sample, then the spelling without brackets.
    FINISH_MATERIAL = %w[ceramic porcelain glass subway tile].freeze

    # A learned same_finish decision names the spelling to show, and joins
    # spellings the word rule cannot ("Inhale Gris 1 Row Stacked").
    def one_per_finish(chips)
      aliases = @finish_alias || {}
      chips.group_by { |c| finish_words(aliases[c[:id]] || c[:name]) }.values.map do |same|
        kept = same.min_by { |c| [c[:standard] ? 0 : 1, c[:swatch_url].present? ? 0 : 1, c[:name].include?('(') ? 1 : 0, c[:name].length] }
        (name = same.filter_map { |c| aliases[c[:id]] }.first) ? kept.merge(name: name) : kept
      end
    end

    def finish_words(name)
      words = name.downcase.scan(/[a-z0-9]+/).map { |w| w == 'rows' ? 'row' : w }.uniq.sort
      (words - FINISH_MATERIAL).presence || words # "Glass" and "Subway" alone stay two
    end

    # What Claude or an admin decided about an option, by kind (CatalogOptionDecision).
    def decided(op, kind)
      decisions.dig(op.option.key, kind)
    end

    def decisions
      @decisions ||= CatalogOptionDecision.applying(@variant.manufacturer_id)
    end

    # Learned pick-one families over the name rules: a family decided for an
    # option sets it, not_family clears it. A family of one is no choice.
    def with_decisions(families, ops)
      ops.each do |op|
        if (family = decided(op, 'family')) then families[op.catalog_option_id] = family
        elsif decisions.dig(op.option.key)&.key?('not_family') then families.delete(op.catalog_option_id)
        end
      end
      counts = families.values.tally
      families.select { |_, f| counts[f] > 1 }
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
        in_place_of: o.in_place_of, price: op.is_standard ? nil : retail[o.id] }.tap do |json|
        # A package that already has one: picking it clears that family, and the reverse.
        (included = decided(op, 'includes')) && json[:includes] = included
      end
    end

    # Standards sheets are titled by product line, not plan series ("Dutch
    # Aspire Sectionals", "Genesis Homes"): take the sheets naming this
    # series, then the one for this home's construction.
    def standard_features
      words = @variant.catalog_plan.series.to_s.downcase.split - %w[champion homes of the]
      # The options book's standards when it brought any (a newer sheet for
      # this series), else the base book's.
      book = @options_book&.standard_features&.exists? ? @options_book : @book
      sheets = book.standard_features.distinct.pluck(:series).select do |s|
        s.nil? || words.any? { |w| s.downcase.match?(/\b#{Regexp.escape(w)}\b/) }
      end
      sheet = best_sheet(sheets.compact)
      book.standard_features.where(series: [nil, sheet].uniq).where(building_code: [nil, @variant.building_code])
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
