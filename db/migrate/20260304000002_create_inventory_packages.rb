class CreateInventoryPackages < ActiveRecord::Migration[8.0]
  def change
    create_table :inventory_packages do |t|
      t.references :vehicle, null: false, foreign_key: true
      t.references :package_template, null: true, foreign_key: true
      t.string :name, null: false
      t.text :description
      t.decimal :price, precision: 12, scale: 2, default: 0
      t.boolean :include_in_total, default: true, null: false
      t.boolean :show_price_in_marketing, default: false, null: false
      t.integer :position, default: 0, null: false
      t.timestamps
    end

    add_index :inventory_packages, [:vehicle_id, :position]
  end
end
