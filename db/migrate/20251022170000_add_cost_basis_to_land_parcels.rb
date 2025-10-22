# frozen_string_literal: true

class AddCostBasisToLandParcels < ActiveRecord::Migration[8.0]
  def change
    add_column :land_parcels, :cost_basis, :decimal, precision: 15, scale: 2
    add_column :land_parcels, :cost_basis_notes, :text
  end
end
