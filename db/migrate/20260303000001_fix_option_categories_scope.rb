# frozen_string_literal: true

# PROBLEM: option_categories.floor_plan_id was NOT NULL, but countertops/cabinets/flooring
# are factory-wide or series-wide choices, NOT per-model.
# FIX: Make floor_plan_id nullable and add scope fields so categories can be:
#   scope='factory'  → applies to all floor plans from that factory (e.g., all Champion Topeka countertops)
#   scope='series'   → applies to a specific series (e.g., Aspire DW structural options)
#   scope='model'    → applies only to one specific floor plan (model-specific options from XLSX)
#   scope='global'   → applies across all factories

class FixOptionCategoriesScope < ActiveRecord::Migration[8.0]
  def change
    # Make floor_plan_id nullable - most categories are NOT model-specific
    change_column_null :option_categories, :floor_plan_id, true

    # What scope this category applies at
    add_column :option_categories, :scope, :string, default: 'factory', null: false

    # Machine-readable key for configurator logic
    # Values: countertop, cabinet, flooring_carpet, flooring_hard, flooring_lino,
    #         siding_vinyl, siding_vertical, siding_fiber_cement, shingles, shutters,
    #         backsplash, shower_tile, wall_treatment, tinted_primer,
    #         structural, appliances, bathroom, other
    add_column :option_categories, :category_key, :string

    # Series name for series-scoped categories (e.g., 'Aspire', 'Prime', 'DGAE')
    add_column :option_categories, :series, :string

    # Factory reference for factory-scoped categories
    add_reference :option_categories, :factory, foreign_key: true

    add_index :option_categories, :scope
    add_index :option_categories, :category_key
    add_index :option_categories, [:factory_id, :category_key]
  end
end
