# frozen_string_literal: true

class CreateSupplierParts < ActiveRecord::Migration[8.0]
  def change
    # Drop any orphaned indexes from previous failed attempts
    execute "DROP INDEX IF EXISTS index_supplier_parts_on_supplier_id" rescue nil
    execute "DROP INDEX IF EXISTS index_supplier_parts_on_part_id" rescue nil
    execute "DROP INDEX IF EXISTS index_supplier_parts_on_supplier_id_and_part_id" rescue nil
    execute "DROP INDEX IF EXISTS index_supplier_parts_on_part_id_and_preferred" rescue nil
    execute "DROP INDEX IF EXISTS index_supplier_parts_on_supplier_sku" rescue nil
    
    return if table_exists?(:supplier_parts)
    
    create_table :supplier_parts do |t|
      t.references :supplier, null: false, foreign_key: true
      t.references :part, null: false, foreign_key: true
      
      # Supplier-specific details
      t.string :supplier_sku # Their part number for this item
      t.decimal :last_cost, precision: 10, scale: 2
      t.integer :lead_time_days
      t.decimal :minimum_order_quantity, precision: 10, scale: 3
      t.boolean :preferred, default: false
      
      # Custom fields support
      t.jsonb :custom_fields, default: {}
      
      t.timestamps
      
      t.index [:supplier_id, :part_id], unique: true
      t.index [:part_id, :preferred]
      t.index :supplier_sku
    end
  end
end
