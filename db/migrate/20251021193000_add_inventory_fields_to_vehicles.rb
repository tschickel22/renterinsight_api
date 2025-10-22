# frozen_string_literal: true

class AddInventoryFieldsToVehicles < ActiveRecord::Migration[8.0]
  def change
    # Add listing type for RV vs Manufactured Home
    add_column :vehicles, :listing_type, :string, null: false, default: 'rv'
    add_index :vehicles, :listing_type

    # Add inventory ID (replacing stock_number as primary identifier)
    add_column :vehicles, :inventory_id, :string
    add_index :vehicles, [:company_id, :inventory_id], unique: true

    # Add manufactured home specific fields
    add_column :vehicles, :serial_number, :string
    add_column :vehicles, :bedrooms, :integer
    add_column :vehicles, :bathrooms, :decimal, precision: 3, scale: 1
    add_column :vehicles, :length, :integer
    add_column :vehicles, :width, :integer
    add_column :vehicles, :square_feet, :integer

    # Add location fields
    add_column :vehicles, :location_city, :string
    add_column :vehicles, :location_state, :string
    add_column :vehicles, :location_zip, :string

    # Add pricing fields for rentals
    add_column :vehicles, :rent_price, :decimal, precision: 15, scale: 2
    add_column :vehicles, :sale_price, :decimal, precision: 15, scale: 2

    # Add images as JSON array
    add_column :vehicles, :images, :json, default: []

    # Add indexes
    add_index :vehicles, [:company_id, :serial_number], unique: true, where: "serial_number IS NOT NULL"
    add_index :vehicles, [:company_id, :vin], unique: true, where: "vin IS NOT NULL"
    
    # Remove old unique index on stock_number
    remove_index :vehicles, :stock_number if index_exists?(:vehicles, :stock_number)
    # Remove old unique index on vin (will be replaced with compound index above)
    remove_index :vehicles, :vin if index_exists?(:vehicles, :vin, unique: true)
    
    # Rename price to sale_price for existing records
    reversible do |dir|
      dir.up do
        execute <<-SQL
          UPDATE vehicles SET sale_price = price WHERE price IS NOT NULL;
        SQL
      end
    end
    
    # Remove old price column
    remove_column :vehicles, :price, :decimal
  end
end
