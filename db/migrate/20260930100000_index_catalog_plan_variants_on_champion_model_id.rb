# frozen_string_literal: true

# Every Champion home saved from a feed looks up its factory model by the
# Champion model id stored on the variant (Catalog::PriceBooks::InventoryLinker).
class IndexCatalogPlanVariantsOnChampionModelId < ActiveRecord::Migration[8.0]
  def change
    add_index :catalog_plan_variants, "(external_ids->>'champion_model_id')",
              name: 'idx_catalog_plan_variants_champion_model_id'
  end
end
