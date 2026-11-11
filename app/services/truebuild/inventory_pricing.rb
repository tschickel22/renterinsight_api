# frozen_string_literal: true

module Truebuild
  # The deal sheet price of a home on the lot that is linked to a price book
  # model (backlog E98). Worked out live by the same engine as the dealer's
  # price list and a new deal sheet, so the three agree and a newly published
  # book shows at once. Nothing is written onto the home, so a price someone
  # typed on it is never overwritten.
  #
  #   retail = (factory base + surcharge - program discount + pack) x markup
  #
  # before options, doc fee, freight, rounding and any sale. When no surcharge
  # applies (none in the book, the dealer's price list or a surcharge rule)
  # the figure is marked before_surcharge, for every dealer (Tom 2026-11-10).
  #
  # #summary carries no cost and is fine for anyone who can see inventory.
  # #breakdown has cost: callers gate it.
  class InventoryPricing
    def initialize(company)
      @company = company
      @memo = {}
      @terms = {}
    end

    # Whether this dealer shows book pricing on inventory for this builder.
    def enabled_for?(manufacturer_id)
      @terms[manufacturer_id] ||= DealerCatalogTerm.effective(@company, manufacturer_id)
      @terms[manufacturer_id].inventory_book_pricing_on?
    end

    # { retail:, before_surcharge: } or nil (not linked, turned off, no book,
    # no markup rule covering it).
    def summary(vehicle)
      line = line_for(vehicle) or return nil
      retail = line[:retail]
      return nil unless retail.to_f.positive?

      { retail: retail.to_f, before_surcharge: surcharge_of(line).zero? }
    end

    # The summary for something a buyer sees (a website, a brochure): only
    # when the dealer shows prices (company pricing on and TrueBuild prices
    # not hidden, which is where they start) and the home has no price of
    # its own. Retail only, never cost.
    def public_summary(vehicle)
      return nil if vehicle.msrp.to_f.positive? || vehicle.sale_price.to_f.positive?
      return nil unless public_prices_shown?

      summary(vehicle)
    end

    # The one price the inventory list shows, sorts and filters on (Tom
    # 2026-11-11). A home linked to a price book shows its deal sheet price,
    # because a deal sheet prices a linked home from the book whatever is typed
    # on it. Any other home shows its own price (Base Sale Price, or the sale
    # price after a Special Discount, plus add-ons counted in the total).
    #   { amount:, source: 'book' | 'home', before_surcharge: }  or nil
    def list_price(vehicle)
      if vehicle.catalog_plan_variant_id && (book = summary(vehicle))
        return { amount: book[:retail], source: 'book', before_surcharge: book[:before_surcharge] }
      end

      own = vehicle.total_home_price.to_f
      own.positive? ? { amount: own.round(2), source: 'home', before_surcharge: false } : nil
    end

    def public_prices_shown?
      return @public_prices_shown if defined?(@public_prices_shown)

      @public_prices_shown = @company.try(:show_pricing) != false &&
                             DealerCatalogTerm.effective(@company, nil).price_display != 'hidden'
    end

    # The summary plus how it is built. include_cost: false leaves out every
    # cost figure (the factory base, the cost line and the program discount).
    def breakdown(vehicle, include_cost:)
      line = line_for(vehicle) or return nil
      sum = summary(vehicle) or return nil
      detail = line[:detail] || {}
      out = sum.merge(
        model_number: vehicle.catalog_plan_variant&.model_number,
        book_name: @memo.dig(key_for(vehicle), :book_name),
        book_id: @memo.dig(key_for(vehicle), :book_id),
        surcharge: surcharge_of(line).to_f,
        pack: detail[:dealer_pack].to_f,
        markup: detail[:rule]
      )
      return out unless include_cost

      out.merge(factory_base: detail[:net_base_price]&.to_f, program_discount: detail[:program_discount].to_f,
                cost: line[:cost]&.to_f)
    end

    private

    def key_for(vehicle)
      [vehicle.catalog_plan_variant_id, vehicle.pack_amount.to_s, vehicle.location_id]
    end

    def line_for(vehicle)
      variant = vehicle.catalog_plan_variant
      return nil unless variant && enabled_for?(variant.manufacturer_id)

      key = key_for(vehicle)
      return @memo[key][:line] if @memo.key?(key)

      engine = PricingEngine.new(company: @company, variant: variant, location: vehicle.location,
                                 include_freight: false, pack: vehicle.pack_amount.presence)
      line = engine.priced? ? engine.home_breakdown : nil
      @memo[key] = { line: line, book_name: (engine.book_name if engine.priced?), book_id: (engine.book_id if engine.priced?) }
      line
    rescue ArgumentError => e
      Rails.logger.info("[InventoryPricing] vehicle #{vehicle.id}: #{e.message}")
      @memo[key] = { line: nil }
      nil
    end

    def surcharge_of(line)
      (line.dig(:detail, :surcharge) || 0).to_d
    end
  end
end
