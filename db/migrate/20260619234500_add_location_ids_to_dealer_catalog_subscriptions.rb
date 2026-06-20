class AddLocationIdsToDealerCatalogSubscriptions < ActiveRecord::Migration[8.0]
  def up
    add_column :dealer_catalog_subscriptions, :location_ids, :jsonb, null: false, default: []
    # Carry the legacy single location_id into the new array.
    execute <<~SQL
      UPDATE dealer_catalog_subscriptions
      SET location_ids = to_jsonb(ARRAY[location_id])
      WHERE location_id IS NOT NULL
    SQL
  end

  def down
    remove_column :dealer_catalog_subscriptions, :location_ids
  end
end
