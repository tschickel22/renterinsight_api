# frozen_string_literal: true

# A surcharge typed on a home (Tom 2026-11-11). The invoice's material
# surcharge wins when the home has an invoice; the price list's fills in for a
# linked home with neither.
class AddSurchargeAmountToVehicles < ActiveRecord::Migration[8.0]
  def change
    add_column :vehicles, :surcharge_amount, :decimal, precision: 15, scale: 2
  end
end
