class AddCatalogLastSyncedValuesToVehicles < ActiveRecord::Migration[8.0]
  # Stores the last value the catalog emitted for each managed field, per vehicle.
  # On re-sync the ingestion service compares current_value vs last_synced[field]:
  # only refreshes when they match (i.e. dealer hasn't touched it since the prior
  # sync). Powers both supplement-then-resync flow and the existing catalog-import
  # path — without it, any dealer edit to a catalog field would be silently
  # overwritten on the next run.
  def change
    add_column :vehicles, :catalog_last_synced_values, :jsonb, default: {}, null: false
  end
end
