# frozen_string_literal: true

# Adds an inventory-level reconditioning cost so a deal/approval can auto-populate
# its reconditioning_cost field from the home (mirrors how selling_price/home_cost
# already source from the vehicle). The accountant can still override on approval.
class AddReconditioningCostToVehicles < ActiveRecord::Migration[8.0]
  def change
    add_column :vehicles, :reconditioning_cost, :decimal, precision: 15, scale: 2 unless column_exists?(:vehicles, :reconditioning_cost)
  end
end
