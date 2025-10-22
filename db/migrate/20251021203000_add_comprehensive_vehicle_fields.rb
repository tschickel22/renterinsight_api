# frozen_string_literal: true

class AddComprehensiveVehicleFields < ActiveRecord::Migration[8.0]
  def change
    # RV Form fields
    add_column :vehicles, :mileage_unit, :string unless column_exists?(:vehicles, :mileage_unit)
    add_column :vehicles, :exterior_color, :string unless column_exists?(:vehicles, :exterior_color)
    add_column :vehicles, :interior_color, :string unless column_exists?(:vehicles, :interior_color)
    add_column :vehicles, :vehicle_interior_type, :string unless column_exists?(:vehicles, :vehicle_interior_type)
    add_column :vehicles, :vehicle_configuration, :string unless column_exists?(:vehicles, :vehicle_configuration)
    add_column :vehicles, :rv_type, :string unless column_exists?(:vehicles, :rv_type)
    add_column :vehicles, :slide_outs, :string unless column_exists?(:vehicles, :slide_outs)
    add_column :vehicles, :awning, :boolean, default: false unless column_exists?(:vehicles, :awning)
    add_column :vehicles, :generator, :boolean, default: false unless column_exists?(:vehicles, :generator)
    add_column :vehicles, :number_of_doors, :string unless column_exists?(:vehicles, :number_of_doors)
    add_column :vehicles, :seating_capacity, :integer unless column_exists?(:vehicles, :seating_capacity)
    add_column :vehicles, :msrp, :decimal, precision: 15, scale: 2 unless column_exists?(:vehicles, :msrp)
    add_column :vehicles, :price_currency, :string, default: 'USD' unless column_exists?(:vehicles, :price_currency)
    
    # Seller information
    add_column :vehicles, :seller_name, :string unless column_exists?(:vehicles, :seller_name)
    add_column :vehicles, :seller_phone, :string unless column_exists?(:vehicles, :seller_phone)
    add_column :vehicles, :seller_address_street, :string unless column_exists?(:vehicles, :seller_address_street)
    add_column :vehicles, :seller_address_city, :string unless column_exists?(:vehicles, :seller_address_city)
    add_column :vehicles, :seller_address_state, :string unless column_exists?(:vehicles, :seller_address_state)
    add_column :vehicles, :seller_address_zip, :string unless column_exists?(:vehicles, :seller_address_zip)
    
    # Media
    add_column :vehicles, :listing_url, :string unless column_exists?(:vehicles, :listing_url)
    add_column :vehicles, :videos, :json, default: [] unless column_exists?(:vehicles, :videos)
    
    # Additional manufactured home fields (if not already present)
    add_column :vehicles, :dwelling_type, :string unless column_exists?(:vehicles, :dwelling_type)
    add_column :vehicles, :foundation_type, :string unless column_exists?(:vehicles, :foundation_type)
    add_column :vehicles, :flooring_type, :string unless column_exists?(:vehicles, :flooring_type)
    add_column :vehicles, :heating_type, :string unless column_exists?(:vehicles, :heating_type)
    add_column :vehicles, :cooling_type, :string unless column_exists?(:vehicles, :cooling_type)
    add_column :vehicles, :water_heater_type, :string unless column_exists?(:vehicles, :water_heater_type)
    add_column :vehicles, :appliances, :json, default: [] unless column_exists?(:vehicles, :appliances)
    add_column :vehicles, :master_bedroom_location, :string unless column_exists?(:vehicles, :master_bedroom_location)
    
    # Pricing detail
    add_column :vehicles, :rent_to_own_price, :decimal, precision: 15, scale: 2 unless column_exists?(:vehicles, :rent_to_own_price)
    add_column :vehicles, :deposit_amount, :decimal, precision: 15, scale: 2 unless column_exists?(:vehicles, :deposit_amount)
    
    # Add indexes for commonly searched fields
    add_index :vehicles, :rv_type unless index_exists?(:vehicles, :rv_type)
    add_index :vehicles, :exterior_color unless index_exists?(:vehicles, :exterior_color)
    add_index :vehicles, :dwelling_type unless index_exists?(:vehicles, :dwelling_type)
  end
end
