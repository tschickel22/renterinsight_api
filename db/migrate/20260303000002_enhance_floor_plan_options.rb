# frozen_string_literal: true

# Adds fields needed to store real Champion decor/option data from:
#   - 2025 Decor Line-Up PDF (countertops, cabinets, flooring, siding colors/names)
#   - Order Form XLSX (option codes, dealer cost, retail price, series restrictions)

class EnhanceFloorPlanOptions < ActiveRecord::Migration[8.0]
  def change
    # Option code from the factory order form (e.g., "WPLNK" for wood plank flooring)
    add_column :floor_plan_options, :option_code, :string

    # Actual dealer cost (FOB factory, from XLSX "Dealer Cost" column)
    add_column :floor_plan_options, :price_dealer, :decimal, precision: 10, scale: 2

    # Actual retail price (from XLSX "Retail Price" = Dealer * markup)
    add_column :floor_plan_options, :price_retail, :decimal, precision: 10, scale: 2

    # S3 URL for the swatch/material image (from Decor Line-Up PDF images)
    add_column :floor_plan_options, :swatch_image_url, :string

    # Material sub-type for grouping within a category
    # Examples: 'hardwood', 'wrapped', 'painted' for cabinets
    #           '3tab', 'architectural' for shingles
    #           'dutch_lap_4', 'dutch_lap_4_5', 'shake' for siding
    #           '15oz', '25oz' for carpet
    add_column :floor_plan_options, :material_type, :string

    # Dimensions label for tile/ceramic options (e.g., "4\" x 12\"")
    add_column :floor_plan_options, :dimensions, :string

    # Series this option is restricted to (nil = all series)
    # Examples: 'Aspire', 'Prime', 'DGAE', 'Gold Star II', 'Summit'
    add_column :floor_plan_options, :series_restriction, :string

    # Which factory this option comes from (nil = all factories)
    add_reference :floor_plan_options, :factory, foreign_key: true

    # Sort key within the decor lineup (Standard options sort before Optional)
    add_column :floor_plan_options, :is_standard_included, :boolean, default: false, null: false

    # Remove the old generic price_impact columns - replaced by price_dealer/price_retail
    # (keep them for now as nullable fallback, set to nil during data import)
    # They can be dropped in a future migration once data is confirmed

    add_index :floor_plan_options, :option_code
    add_index :floor_plan_options, :series_restriction
    add_index :floor_plan_options, :is_standard_included
    add_index :floor_plan_options, [:factory_id, :option_code]
  end
end
