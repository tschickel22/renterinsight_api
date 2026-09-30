# frozen_string_literal: true

# A factory model number is unique within a series, not within a manufacturer:
# Champion's Topeka package prices 2848M32160 as the Aspire 48' Lancaster at
# $54,695 and as a Genesis ranch at $81,645. Variants carry their series and
# are unique on (manufacturer, series, model number).
class AddSeriesToCatalogPlanVariants < ActiveRecord::Migration[8.0]
  def up
    add_column :catalog_plan_variants, :series, :string
    execute <<~SQL.squish
      UPDATE catalog_plan_variants v SET series = p.series
      FROM catalog_plans p WHERE p.id = v.catalog_plan_id
    SQL
    remove_index :catalog_plan_variants, [:manufacturer_id, :model_number]
    add_index :catalog_plan_variants, "manufacturer_id, COALESCE(series, ''), model_number",
              unique: true, name: 'idx_catalog_plan_variants_unique_model'
    add_index :catalog_plan_variants, [:manufacturer_id, :model_number]
  end

  def down
    remove_index :catalog_plan_variants, [:manufacturer_id, :model_number]
    remove_index :catalog_plan_variants, name: 'idx_catalog_plan_variants_unique_model'
    add_index :catalog_plan_variants, [:manufacturer_id, :model_number], unique: true
    remove_column :catalog_plan_variants, :series
  end
end
