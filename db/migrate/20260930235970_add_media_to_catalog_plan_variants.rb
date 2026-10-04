# frozen_string_literal: true

# Photos, elevations, floor plans and tours of a model, from the
# manufacturer's own site, for the buyer designer (Truebuild::ModelMedia).
class AddMediaToCatalogPlanVariants < ActiveRecord::Migration[8.0]
  def change
    add_column :catalog_plan_variants, :media, :jsonb, default: {}, null: false
  end
end
