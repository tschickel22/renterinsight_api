# frozen_string_literal: true

module Websites
  # The price a buyer sees on a home in public inventory, and whether prices
  # show at all. One place for the public inventory API and the Edit Website
  # Inventory tab's "Buyers see", so the two never disagree.
  #
  # site: Websites::InventorySettings for the DealerTide site asking, or nil
  # (an embed or the dealer's own website). A site's "Show asking prices"
  # switch decides for that site (a site whose price list prices are held,
  # InventorySettings#price_list_held?, shows those as it did before the
  # switch). Without a site the company-wide behavior stays: the home's own price always goes out (the embed hides it on the
  # card), and a price list price only when the company shows prices and
  # TrueBuild prices are not hidden (InventoryPricing#public_summary).
  class PublicPrice
    def initialize(company, site: nil)
      @company = company
      @site = site
    end

    # False only when a site has its switch off.
    def prices_shown?
      @site.nil? || @site.show_prices?
    end

    # For the monthly payment line: a payment is a price.
    def payments_shown?
      @site ? @site.show_prices? : @company.try(:show_pricing) != false
    end

    # The sale price to show, or nil: none set, or a special discount past
    # its end date.
    def sale_price(vehicle)
      return nil unless vehicle.sale_price.present? && vehicle.sale_price.positive?
      return nil if vehicle.sale_expired? || vehicle.sale_not_started?

      vehicle.sale_price.to_f.round(2)
    end

    # { amount:, type: 'sale'|'base'|'rent', source: } or nil. Ignores the
    # switch; #display applies it.
    def price(vehicle)
      sale = sale_price(vehicle)
      if sale
        { amount: sale, type: 'sale' }
      elsif vehicle.msrp.present? && vehicle.msrp.positive?
        # The dealer's base asking price, when there is no sale.
        { amount: vehicle.msrp.to_f.round(2), type: 'base' }
      elsif vehicle.rent_price.present? && vehicle.rent_price.positive?
        { amount: vehicle.rent_price.to_f.round(2), type: 'rent' }
      elsif (book = book_price(vehicle))
        # E98: a home with no price of its own, linked to a price book model,
        # shows its deal sheet selling price. One number, never itemized.
        { amount: book[:retail].round(2), type: 'base', source: 'price_book' }
      end
    end

    def display(vehicle)
      prices_shown? ? price(vehicle) : nil
    end

    # The price book's selling price for a home with none of its own, or nil.
    # Retail only, never cost.
    def book_price(vehicle)
      return nil unless vehicle.catalog_plan_variant_id && @company

      if @site && !@site.price_list_held?
        return nil if vehicle.msrp.to_f.positive? || vehicle.sale_price.to_f.positive?

        inventory_pricing.summary(vehicle)
      else
        # No site, or a site still holding price list prices: as before.
        inventory_pricing.public_summary(vehicle)
      end
    rescue StandardError => e
      Rails.logger.warn("[Websites::PublicPrice] book price for #{vehicle.id}: #{e.class} #{e.message}")
      nil
    end

    def inventory_pricing
      @inventory_pricing ||= Truebuild::InventoryPricing.new(@company)
    end
  end
end
