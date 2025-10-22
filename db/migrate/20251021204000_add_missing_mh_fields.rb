# frozen_string_literal: true

class AddMissingMhFields < ActiveRecord::Migration[8.0]
  def change
    # Address fields
    add_column :vehicles, :location_type, :string unless column_exists?(:vehicles, :location_type)
    add_column :vehicles, :community_key, :string unless column_exists?(:vehicles, :community_key)
    add_column :vehicles, :address1, :string unless column_exists?(:vehicles, :address1)
    add_column :vehicles, :address2, :string unless column_exists?(:vehicles, :address2)
    add_column :vehicles, :county_name, :string unless column_exists?(:vehicles, :county_name)
    
    # Construction materials
    add_column :vehicles, :exterior_material, :string unless column_exists?(:vehicles, :exterior_material)
    add_column :vehicles, :roof_material, :string unless column_exists?(:vehicles, :roof_material)
    add_column :vehicles, :insulation_type, :string unless column_exists?(:vehicles, :insulation_type)
    add_column :vehicles, :ceiling_type, :string unless column_exists?(:vehicles, :ceiling_type)
    add_column :vehicles, :wall_type, :string unless column_exists?(:vehicles, :wall_type)
    
    # Additional boolean features
    add_column :vehicles, :has_storage, :boolean, default: false unless column_exists?(:vehicles, :has_storage)
    add_column :vehicles, :thermopane, :boolean, default: false unless column_exists?(:vehicles, :thermopane)
    add_column :vehicles, :gutters, :boolean, default: false unless column_exists?(:vehicles, :gutters)
    add_column :vehicles, :shutters, :boolean, default: false unless column_exists?(:vehicles, :shutters)
    add_column :vehicles, :cathedral_ceiling, :boolean, default: false unless column_exists?(:vehicles, :cathedral_ceiling)
    add_column :vehicles, :ceiling_fan, :boolean, default: false unless column_exists?(:vehicles, :ceiling_fan)
    add_column :vehicles, :skylight, :boolean, default: false unless column_exists?(:vehicles, :skylight)
    add_column :vehicles, :walkin_closet, :boolean, default: false unless column_exists?(:vehicles, :walkin_closet)
    add_column :vehicles, :laundry_room, :boolean, default: false unless column_exists?(:vehicles, :laundry_room)
    add_column :vehicles, :pantry, :boolean, default: false unless column_exists?(:vehicles, :pantry)
    add_column :vehicles, :sun_room, :boolean, default: false unless column_exists?(:vehicles, :sun_room)
    add_column :vehicles, :basement, :boolean, default: false unless column_exists?(:vehicles, :basement)
    add_column :vehicles, :garden_tub, :boolean, default: false unless column_exists?(:vehicles, :garden_tub)
    
    # Appliances (as booleans)
    add_column :vehicles, :garbage_disposal, :boolean, default: false unless column_exists?(:vehicles, :garbage_disposal)
    add_column :vehicles, :refrigerator, :boolean, default: false unless column_exists?(:vehicles, :refrigerator)
    add_column :vehicles, :microwave, :boolean, default: false unless column_exists?(:vehicles, :microwave)
    add_column :vehicles, :oven, :boolean, default: false unless column_exists?(:vehicles, :oven)
    add_column :vehicles, :dishwasher, :boolean, default: false unless column_exists?(:vehicles, :dishwasher)
    add_column :vehicles, :clothes_washer, :boolean, default: false unless column_exists?(:vehicles, :clothes_washer)
    add_column :vehicles, :clothes_dryer, :boolean, default: false unless column_exists?(:vehicles, :clothes_dryer)
    
    # Pricing and terms
    add_column :vehicles, :utilities, :decimal, precision: 10, scale: 2 unless column_exists?(:vehicles, :utilities)
    add_column :vehicles, :terms, :text unless column_exists?(:vehicles, :terms)
    add_column :vehicles, :repo, :boolean, default: false unless column_exists?(:vehicles, :repo)
    add_column :vehicles, :package_type, :string unless column_exists?(:vehicles, :package_type)
    add_column :vehicles, :sale_pending, :boolean, default: false unless column_exists?(:vehicles, :sale_pending)
    
    # Media
    add_column :vehicles, :photo_url, :string unless column_exists?(:vehicles, :photo_url)
    add_column :vehicles, :virtual_tour, :string unless column_exists?(:vehicles, :virtual_tour)
    add_column :vehicles, :sales_photo, :string unless column_exists?(:vehicles, :sales_photo)
  end
end
