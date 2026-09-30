# frozen_string_literal: true

# Decor sheets and the finish samples read from them. Platform data: a
# factory's samples are the same for every dealer who sells its homes.
class CreateCatalogSwatches < ActiveRecord::Migration[8.0]
  def change
    create_table :catalog_swatch_sheets do |t|
      t.references :manufacturer, null: false, foreign_key: true
      t.references :factory, foreign_key: { on_delete: :nullify }
      t.string :filename, null: false
      t.string :storage_ref, null: false
      t.string :status, null: false, default: 'queued'
      t.text :error
      t.integer :swatch_count, null: false, default: 0
      t.jsonb :missed, null: false, default: []
      t.decimal :cost_usd, precision: 10, scale: 4
      t.timestamps
    end

    create_table :catalog_swatches do |t|
      t.references :manufacturer, null: false, foreign_key: true
      t.references :factory, foreign_key: { on_delete: :nullify }
      t.references :catalog_swatch_sheet, foreign_key: { on_delete: :nullify }
      t.string :set_name, null: false
      t.string :name, null: false
      t.string :note
      t.string :hex
      t.string :image_url, null: false
      t.integer :page
      t.timestamps
    end
    add_index :catalog_swatches, 'manufacturer_id, COALESCE(factory_id, 0), lower(set_name), lower(name)',
              unique: true, name: 'idx_catalog_swatches_unique_name'
  end
end
