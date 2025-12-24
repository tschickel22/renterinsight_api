# frozen_string_literal: true

# Add remaining RVT.com syndication fields to vehicles table
# Only adds fields that don't already exist
class AddRvtFieldsToVehicles < ActiveRecord::Migration[8.0]
  def change
    # RV Class/Type - CRITICAL field for RVT.com (rv_type exists but this is more specific)
    add_column :vehicles, :rv_class, :string, comment: 'RV class type (Class A/B/C, Travel Trailer, Fifth Wheel, etc.)' unless column_exists?(:vehicles, :rv_class)
    
    # Note: fuel_type already exists from 20251021202000_add_missing_columns_to_vehicles
    
    # Engine Information (fuel_type already exists)
    add_column :vehicles, :engine_make, :string, comment: 'Engine manufacturer (Ford, Chevy, Cummins, etc.)' unless column_exists?(:vehicles, :engine_make)
    add_column :vehicles, :engine_type, :string, comment: 'Engine type (V8, V10, I6, etc.)' unless column_exists?(:vehicles, :engine_type)
    
    # Mileage - CRITICAL for used RVs (note: mileage_unit already exists)
    add_column :vehicles, :mileage, :integer, comment: 'Odometer reading in miles' unless column_exists?(:vehicles, :mileage)
    
    # Sleeping & Comfort (sleeps already exists, renaming to sleeping_capacity for RVT compatibility)
    add_column :vehicles, :sleeping_capacity, :integer, comment: 'Number of people it sleeps' unless column_exists?(:vehicles, :sleeping_capacity)
    add_column :vehicles, :num_air_conditioners, :integer, comment: 'Number of AC units', default: 0 unless column_exists?(:vehicles, :num_air_conditioners)
    
    # Slide Outs - VERY IMPORTANT for RVs (slide_outs exists as string, adding slideouts as integer for RVT)
    add_column :vehicles, :slideouts, :integer, comment: 'Number of slide-outs', default: 0 unless column_exists?(:vehicles, :slideouts)
    
    # Note: exterior_color already exists from 20251021203000_add_comprehensive_vehicle_fields
    
    # Awnings (awning exists as boolean, adding awnings as integer for count)
    add_column :vehicles, :awnings, :integer, comment: 'Number of awnings', default: 0 unless column_exists?(:vehicles, :awnings)
    
    # Utilities & Capacities
    add_column :vehicles, :fresh_water_capacity, :decimal, precision: 8, scale: 2, comment: 'Fresh water tank capacity in gallons' unless column_exists?(:vehicles, :fresh_water_capacity)
    add_column :vehicles, :gray_water_capacity, :decimal, precision: 8, scale: 2, comment: 'Gray water tank capacity in gallons' unless column_exists?(:vehicles, :gray_water_capacity)
    add_column :vehicles, :black_water_capacity, :decimal, precision: 8, scale: 2, comment: 'Black water tank capacity in gallons' unless column_exists?(:vehicles, :black_water_capacity)
    add_column :vehicles, :propane_capacity, :decimal, precision: 8, scale: 2, comment: 'Propane tank capacity in gallons' unless column_exists?(:vehicles, :propane_capacity)
    
    # Weight Specifications (weight already exists, adding specific weight types)
    add_column :vehicles, :dry_weight, :integer, comment: 'Dry weight (UVW) in pounds' unless column_exists?(:vehicles, :dry_weight)
    add_column :vehicles, :gross_weight, :integer, comment: 'Gross vehicle weight rating (GVWR) in pounds' unless column_exists?(:vehicles, :gross_weight)
    add_column :vehicles, :hitch_weight, :integer, comment: 'Hitch/tongue weight in pounds' unless column_exists?(:vehicles, :hitch_weight)
    add_column :vehicles, :cargo_capacity, :integer, comment: 'Cargo carrying capacity in pounds' unless column_exists?(:vehicles, :cargo_capacity)
    
    # Additional Features (generator already exists as boolean)
    add_column :vehicles, :leveling_jacks, :boolean, default: false, comment: 'Has automatic leveling jacks' unless column_exists?(:vehicles, :leveling_jacks)
    add_column :vehicles, :self_contained, :boolean, default: false, comment: 'Fully self-contained (bathroom, kitchen, etc.)' unless column_exists?(:vehicles, :self_contained)
    add_column :vehicles, :solar_panels, :boolean, default: false, comment: 'Has solar panel system' unless column_exists?(:vehicles, :solar_panels)
    add_column :vehicles, :backup_camera, :boolean, default: false, comment: 'Has backup camera' unless column_exists?(:vehicles, :backup_camera)
    add_column :vehicles, :satellite_tv, :boolean, default: false, comment: 'Has satellite TV capability' unless column_exists?(:vehicles, :satellite_tv)
    
    # Generator Specifics (generator boolean already exists)
    add_column :vehicles, :generator_make, :string, comment: 'Generator manufacturer' unless column_exists?(:vehicles, :generator_make)
    add_column :vehicles, :generator_hours, :integer, comment: 'Generator hours used' unless column_exists?(:vehicles, :generator_hours)
    add_column :vehicles, :generator_fuel_type, :string, comment: 'Generator fuel type (Gas, Diesel, Propane)' unless column_exists?(:vehicles, :generator_fuel_type)
    
    # Media & Marketing (videos already exists as json, listing_url already exists)
    add_column :vehicles, :video_url, :string, comment: 'YouTube or other video URL' unless column_exists?(:vehicles, :video_url)
    add_column :vehicles, :virtual_tour_url, :string, comment: '360° virtual tour URL' unless column_exists?(:vehicles, :virtual_tour_url)
    
    # Additional text field for special features/notes
    add_column :vehicles, :special_features, :text, comment: 'Additional special features or upgrades' unless column_exists?(:vehicles, :special_features)
    
    # Overlay text for syndication (promotional text)
    add_column :vehicles, :overlay_text, :string, comment: 'Promotional overlay text for listings' unless column_exists?(:vehicles, :overlay_text)
    
    # Indexes for commonly searched fields
    add_index :vehicles, :rv_class unless index_exists?(:vehicles, :rv_class)
    add_index :vehicles, :sleeping_capacity unless index_exists?(:vehicles, :sleeping_capacity)
    add_index :vehicles, :slideouts unless index_exists?(:vehicles, :slideouts)
    add_index :vehicles, [:mileage, :year], name: 'index_vehicles_on_mileage_and_year' unless index_exists?(:vehicles, [:mileage, :year], name: 'index_vehicles_on_mileage_and_year')
  end
end
