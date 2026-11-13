# frozen_string_literal: true

# Deal Desk may change the home's selling price for one scenario. The override is the
# scenario's own price for the home (nil = use the home's price, unit_price_snapshot), so
# the Recap, Solve, the payment grid and Compare all price the same deal. Applying the
# scenario writes it to the deal's home line. Additive and nullable, so old code ignores it.
class AddSellingPriceOverrideToDealDeskScenarios < ActiveRecord::Migration[8.0]
  def change
    add_column :deal_desk_scenarios, :selling_price_override, :decimal, precision: 15, scale: 2
  end
end
