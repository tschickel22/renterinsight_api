# frozen_string_literal: true

class AddMissingColumnsToVehicles < ActiveRecord::Migration[8.0]
  def change
    # RV-specific columns
    add_column :vehicles, :body_style, :string unless column_exists?(:vehicles, :body_style)
    add_column :vehicles, :fuel_type, :string unless column_exists?(:vehicles, :fuel_type)
    add_column :vehicles, :transmission, :string unless column_exists?(:vehicles, :transmission)
    add_column :vehicles, :sleeps, :integer unless column_exists?(:vehicles, :sleeps)
    add_column :vehicles, :weight, :integer unless column_exists?(:vehicles, :weight)

    # Manufactured Home specific columns
    add_column :vehicles, :home_type, :string unless column_exists?(:vehicles, :home_type)
    add_column :vehicles, :roof_type, :string unless column_exists?(:vehicles, :roof_type)
    add_column :vehicles, :siding_type, :string unless column_exists?(:vehicles, :siding_type)
    add_column :vehicles, :lot_rent, :decimal, precision: 10, scale: 2 unless column_exists?(:vehicles, :lot_rent)
    add_column :vehicles, :community_name, :string unless column_exists?(:vehicles, :community_name)

    # Multi-section dimensions for manufactured homes
    add_column :vehicles, :width1, :integer unless column_exists?(:vehicles, :width1)
    add_column :vehicles, :length1, :integer unless column_exists?(:vehicles, :length1)
    add_column :vehicles, :width2, :integer unless column_exists?(:vehicles, :width2)
    add_column :vehicles, :length2, :integer unless column_exists?(:vehicles, :length2)
    add_column :vehicles, :width3, :integer unless column_exists?(:vehicles, :width3)
    add_column :vehicles, :length3, :integer unless column_exists?(:vehicles, :length3)

    # Amenities (booleans)
    add_column :vehicles, :garage, :boolean, default: false unless column_exists?(:vehicles, :garage)
    add_column :vehicles, :carport, :boolean, default: false unless column_exists?(:vehicles, :carport)
    add_column :vehicles, :deck, :boolean, default: false unless column_exists?(:vehicles, :deck)
    add_column :vehicles, :patio, :boolean, default: false unless column_exists?(:vehicles, :patio)
    add_column :vehicles, :fireplace, :boolean, default: false unless column_exists?(:vehicles, :fireplace)
    add_column :vehicles, :central_air, :boolean, default: false unless column_exists?(:vehicles, :central_air)

    # Add indexes for commonly queried fields
    add_index :vehicles, :home_type unless index_exists?(:vehicles, :home_type)
    add_index :vehicles, :body_style unless index_exists?(:vehicles, :body_style)
  end
end
