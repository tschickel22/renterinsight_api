class CreateDealProducts < ActiveRecord::Migration[7.0]
  def change
    create_table :deal_products do |t|
      t.references :deal, null: false, foreign_key: true
      t.references :product, null: true  # Foreign key removed - products table doesn't exist yet
      t.string :product_name
      t.string :product_sku
      t.integer :quantity, default: 1
      t.decimal :unit_price, precision: 12, scale: 2, default: 0.0
      t.decimal :discount, precision: 12, scale: 2, default: 0.0
      t.decimal :tax, precision: 12, scale: 2, default: 0.0
      t.decimal :total, precision: 12, scale: 2, default: 0.0
      t.text :notes

      t.timestamps
    end

    add_index :deal_products, [:deal_id, :product_id]
  end
end
