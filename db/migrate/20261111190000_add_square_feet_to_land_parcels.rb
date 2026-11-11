# frozen_string_literal: true

# Land can be sized in square feet as well as acres (Tom 2026-11-11). acreage
# stays the figure filters, sorts and price per acre use; square_feet and
# size_unit keep what the dealer typed so it shows back the same way.
class AddSquareFeetToLandParcels < ActiveRecord::Migration[8.0]
  def change
    add_column :land_parcels, :square_feet, :decimal, precision: 14, scale: 2
    add_column :land_parcels, :size_unit, :string, null: false, default: 'acres'
  end
end
