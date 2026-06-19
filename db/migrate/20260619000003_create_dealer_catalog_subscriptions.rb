class CreateDealerCatalogSubscriptions < ActiveRecord::Migration[8.0]
  def change
    create_table :dealer_catalog_subscriptions do |t|
      t.references :company, null: false, foreign_key: true, index: true
      t.references :catalog_source, null: false, foreign_key: true, index: true
      t.boolean :enabled, null: false, default: true
      t.bigint  :location_id
      t.timestamps
    end

    add_index :dealer_catalog_subscriptions, [:company_id, :catalog_source_id],
              unique: true, name: 'idx_dealer_catalog_subs_unique'
  end
end
