# frozen_string_literal: true

# Adds fields needed to store real Champion floor plan data from:
#   - 2026 Aspire Sectional Net pricing PDF (net dealer price, box size)
#   - S3 transfers (folder path for images)
#   - Virtual tours spreadsheet (already seeded but need url column)

class EnhanceFloorPlans < ActiveRecord::Migration[8.0]
  def change
    # Net dealer price (FOB factory) from pricing PDF
    # This is the actual cost the dealer pays, not a range
    add_column :floor_plans, :net_price, :decimal, precision: 10, scale: 2

    # Box size string as printed on pricing sheet (e.g., "28' x 48'")
    add_column :floor_plans, :box_size, :string

    # HUD vs Modular designation
    add_column :floor_plans, :home_type, :string, default: 'hud'

    # S3 folder prefix for this model's images
    # e.g., "floor-plans/champion/topeka-in/champion-homes/genesis/emerald-sky"
    add_column :floor_plans, :s3_folder_path, :string

    # Matterport virtual tour URL
    add_column :floor_plans, :virtual_tour_url, :string

    # PDF spec sheet URL (if available)
    add_column :floor_plans, :spec_sheet_url, :string

    # Pricing effective date (PDFs are date-stamped)
    add_column :floor_plans, :price_effective_date, :date

    # Brand within a manufacturer (Champion has: Champion Homes, Redman, Dutch Housing)
    add_column :floor_plans, :brand, :string

    add_index :floor_plans, :home_type
    add_index :floor_plans, :brand
    add_index :floor_plans, :net_price
  end
end
