class AddCatalogFieldsToVehicles < ActiveRecord::Migration[8.0]
  def change
    add_column :vehicles, :catalog_source_id, :bigint unless column_exists?(:vehicles, :catalog_source_id)
    add_column :vehicles, :catalog_source_key, :string unless column_exists?(:vehicles, :catalog_source_key)
    add_column :vehicles, :catalog_content_hash, :string unless column_exists?(:vehicles, :catalog_content_hash)
    add_column :vehicles, :catalog_last_seen_at, :datetime unless column_exists?(:vehicles, :catalog_last_seen_at)

    unless index_exists?(:vehicles, [:catalog_source_id, :catalog_source_key], name: 'idx_vehicles_catalog_dedup')
      add_index :vehicles, [:catalog_source_id, :catalog_source_key], name: 'idx_vehicles_catalog_dedup'
    end
  end
end
