class CreateInvoiceInventoryUsage < ActiveRecord::Migration[8.0]
  def change
    create_table :invoice_inventory_usages do |t|
      t.references :company, null: false, foreign_key: true
      t.references :invoice, null: false, foreign_key: true
      t.references :invoice_item, null: false, foreign_key: true
      
      # Polymorphic reference to the inventory item (Part, Vehicle, LandParcel)
      t.string :itemable_type, null: false
      t.integer :itemable_id, null: false
      
      t.decimal :quantity_used, precision: 10, scale: 2, null: false, default: 1.0
      t.boolean :marked, default: false, null: false
      t.datetime :marked_at
      t.references :marked_by, foreign_key: { to_table: :users }
      
      t.boolean :is_deleted, default: false
      t.timestamps
    end
    
    add_index :invoice_inventory_usages, [:itemable_type, :itemable_id]
    add_index :invoice_inventory_usages, :marked_at
    add_index :invoice_inventory_usages, [:invoice_item_id, :itemable_type, :itemable_id], 
              name: 'index_invoice_inv_usages_on_item_and_itemable', unique: true
  end
end
