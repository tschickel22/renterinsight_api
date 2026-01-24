class CreateQuoteInventoryUsage < ActiveRecord::Migration[8.0]
  def change
    create_table :quote_inventory_usages do |t|
      t.references :quote, null: false, foreign_key: true
      t.references :part, null: false, foreign_key: true
      t.references :location, null: true, foreign_key: true
      
      t.decimal :quantity, precision: 10, scale: 2, null: false
      t.decimal :unit_cost, precision: 10, scale: 2
      t.decimal :unit_price, precision: 10, scale: 2
      
      t.integer :item_index, comment: 'Index in the quote.items JSONB array'
      
      t.boolean :used, default: false, null: false
      t.datetime :used_at
      t.references :used_by, foreign_key: { to_table: :users }
      
      t.text :notes
      t.timestamps
    end
    
    add_index :quote_inventory_usages, [:quote_id, :part_id]
    add_index :quote_inventory_usages, :used
  end
end
