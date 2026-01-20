class FixInvoiceInventoryUsageColumns < ActiveRecord::Migration[8.0]
  def change
    # Add the missing 'marked' boolean column
    add_column :invoice_inventory_usages, :marked, :boolean, default: false, null: false
    
    # Rename marked_used_at to marked_at
    rename_column :invoice_inventory_usages, :marked_used_at, :marked_at
    
    # Change quantity_used from integer to decimal
    change_column :invoice_inventory_usages, :quantity_used, :decimal, precision: 10, scale: 2, null: false, default: 1.0
    
    # Add the missing unique index
    add_index :invoice_inventory_usages, [:invoice_item_id, :itemable_type, :itemable_id], 
              name: 'index_invoice_inv_usages_on_item_and_itemable', unique: true
  end
end
