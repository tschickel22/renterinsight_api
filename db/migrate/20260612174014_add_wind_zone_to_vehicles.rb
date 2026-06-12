# frozen_string_literal: true

# Wind zone (1-3) on the inventory home itself. Previously only captured on the
# VehicleInvoice (Max Advance cost-basis). Dealers in coastal markets (LA/FL)
# need it on the home record for allowance math (zone 2/3 per-side adders) and
# it flows down to the invoice when one is created.
class AddWindZoneToVehicles < ActiveRecord::Migration[8.0]
  def change
    add_column :vehicles, :wind_zone, :integer
  end
end
