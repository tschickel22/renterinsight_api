# frozen_string_literal: true

module DealDesk
  # The price of a home on its own, for the desk's "unit slot".
  #
  # On the desk a home is priced as two parts, the same way a deal carries it: the home line
  # (this price) plus its included packages as separate add-on lines. Vehicle#total_home_price
  # is the home WITH its included packages (and any special discount), so the home line is that
  # total less the packages. Pricing a swapped-in or compared home this way keeps the Recap,
  # the Compare row and the unit swap on one number, and never counts a package twice.
  #
  # Falls back to msrp, then sale_price, when the resolved total is missing. Returns 0.0 when
  # the home has no price anywhere (callers decide what that means).
  module UnitPrice
    module_function

    def home_price(vehicle)
      return 0.0 if vehicle.nil?

      total = vehicle.respond_to?(:total_home_price) ? vehicle.total_home_price.to_f : 0.0
      if total.positive?
        base = (total - included_package_total(vehicle)).round(2)
        return base if base.positive?
      end

      [vehicle.msrp.to_f, vehicle.sale_price.to_f].find(&:positive?) || 0.0
    end

    def included_package_total(vehicle)
      return 0.0 unless vehicle.respond_to?(:inventory_packages)

      vehicle.inventory_packages.included_in_total.sum(:price).to_f
    end
  end
end
