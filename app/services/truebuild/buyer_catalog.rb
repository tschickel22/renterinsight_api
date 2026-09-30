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

    def call
      offered = offered_prices
      engine = PricingEngine.new(company: @company, variant: @variant, location: @location,
                                 option_ids: offered.map(&:catalog_option_id).uniq).call
      base = engine.lines.find { |l| l[:kind] == 'base' }
      retail_by_option = engine.lines.select { |l| l[:kind] == 'option' }.to_h { |l| [l[:option_id], l[:retail]] }
      show = SHOWS_PRICES.include?(@terms.price_display) && base[:retail].present?
      monthly = SHOWS_MONTHLY.include?(@terms.price_display) && base[:retail].present? && payments.enabled?

      {
        variant: variant_json,
        display: { mode: @terms.price_display, show_prices: show, show_monthly: monthly,
                   payment_terms: (payments.terms if monthly) },
        base_price: show ? base[:retail] : nil,
        base_monthly: monthly ? payments.monthly(base[:retail]) : nil,
        groups: groups(offered, show ? retail_by_option : {}),
        standard_features: standard_features,
        media: media
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
    def price(option_ids)
      result = PricingEngine.new(company: @company, variant: @variant, location: @location,
                                 option_ids: allowed(option_ids)).call
      show = SHOWS_PRICES.include?(@terms.price_display) && result.totals[:retail].present?
      monthly = SHOWS_MONTHLY.include?(@terms.price_display) && result.totals[:retail].present? && payments.enabled?
      { show_prices: show, total: show ? result.totals[:retail] : nil,
        monthly: monthly ? payments.monthly(result.totals[:retail]) : nil,
        lines: show ? result.retail_only[:lines] : [], book_id: result.book&.id, option_ids: allowed(option_ids) }
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
    def groups(prices, retail)
      prices.uniq(&:catalog_option_id).group_by { |op| op.option.group }
            .sort_by { |g, _| [g.position.to_i, g.name] }.map do |group, ops|
        colors, others = ops.partition { |op| op.option.kind == 'color' }
        families = OptionFamilies.for(others.map(&:option))
        {
          id: group.id, name: group.name,
          color_sets: colors.group_by { |op| op.option.metadata['color_set'].presence || 'Colors' }
                            .map { |set, cs| { name: set, options: cs.map { |op| option_json(op, retail) }.sort_by { |o| o[:name] } } }
                            .sort_by { |s| s[:name] },
          # A family's members sit together, under the first one's name.
          options: others.map { |op| option_json(op, retail).merge(family: families[op.catalog_option_id]) }
                         .sort_by { |o| [o[:standard] ? 0 : 1, (o[:family] || o[:name]).downcase, o[:name].downcase] }
        }
      end.reject { |g| g[:color_sets].empty? && g[:options].empty? }
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
