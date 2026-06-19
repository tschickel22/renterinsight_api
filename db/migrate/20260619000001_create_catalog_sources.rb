class CreateCatalogSources < ActiveRecord::Migration[8.0]
  def change
    create_table :catalog_sources do |t|
      t.string   :name, null: false
      t.string   :adapter_type, null: false
      t.string   :base_url
      t.string   :manufacturer_id
      t.jsonb    :config, null: false, default: {}
      t.boolean  :enabled, null: false, default: false
      t.string   :schedule, null: false, default: 'nightly'
      t.decimal  :extraction_threshold, precision: 4, scale: 2, null: false, default: 0.80
      t.datetime :last_run_at
      t.string   :last_run_status, null: false, default: 'never_run'
      t.boolean  :is_deleted, null: false, default: false
      t.datetime :deleted_at
      t.timestamps
    end

    add_index :catalog_sources, :adapter_type
    add_index :catalog_sources, [:enabled, :is_deleted]
  end
end
