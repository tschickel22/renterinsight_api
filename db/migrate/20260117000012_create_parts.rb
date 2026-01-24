# frozen_string_literal: true

class CreateParts < ActiveRecord::Migration[8.0]
  def change
    # Drop any orphaned indexes from previous failed attempts
    execute "DROP INDEX IF EXISTS index_parts_on_company_id" rescue nil
    execute "DROP INDEX IF EXISTS index_parts_on_category_id" rescue nil
    execute "DROP INDEX IF EXISTS index_parts_on_created_by_id" rescue nil
    execute "DROP INDEX IF EXISTS index_parts_on_updated_by_id" rescue nil
    execute "DROP INDEX IF EXISTS index_parts_on_company_id_and_sku" rescue nil
    execute "DROP INDEX IF EXISTS index_parts_on_company_id_and_active" rescue nil
    execute "DROP INDEX IF EXISTS index_parts_on_company_id_and_category_id" rescue nil
    execute "DROP INDEX IF EXISTS index_parts_on_barcode" rescue nil
    execute "DROP INDEX IF EXISTS index_parts_on_manufacturer_part_no" rescue nil
    execute "DROP INDEX IF EXISTS index_parts_on_qb_item_id" rescue nil
    execute "DROP INDEX IF EXISTS index_parts_on_company_id_and_name" rescue nil
    
    return if table_exists?(:parts)
    
    create_table :parts do |t|
      t.references :company, null: false, foreign_key: true
      
      # Core identification
      t.string :sku, null: false
      t.string :name, null: false
      t.text :description
      t.references :category, foreign_key: { to_table: :part_categories }
      
      # Classification
      t.string :uom, default: 'each' # unit of measure: each, box, case, lb, ft, etc.
      t.string :barcode
      t.string :manufacturer_part_no
      t.string :manufacturer_name
      
      # Pricing (all decimals precision: 10, scale: 2)
      t.decimal :default_cost, precision: 10, scale: 2
      t.decimal :average_cost, precision: 10, scale: 2 # Calculated from receipts
      t.decimal :last_cost, precision: 10, scale: 2 # Most recent purchase cost
      t.decimal :list_price, precision: 10, scale: 2
      t.decimal :sale_price, precision: 10, scale: 2
      t.boolean :taxable, default: true
      
      # Inventory tracking
      t.boolean :is_serialized, default: false # Track by serial numbers
      t.boolean :is_lot_tracked, default: false # Track by lot/batch numbers
      t.string :inventory_method, default: 'average_cost' # average_cost, fifo, lifo
      
      # Physical attributes (optional, useful for shipping/storage)
      t.decimal :weight_lbs, precision: 8, scale: 2
      t.decimal :length_inches, precision: 8, scale: 2
      t.decimal :width_inches, precision: 8, scale: 2
      t.decimal :height_inches, precision: 8, scale: 2
      
      # QuickBooks Integration
      t.string :qb_item_id
      t.string :qb_income_account
      t.string :qb_expense_account
      t.string :qb_asset_account
      
      # Status
      t.boolean :active, default: true
      t.boolean :is_deleted, default: false
      t.datetime :deleted_at
      
      # Custom fields support
      t.jsonb :custom_fields, default: {}
      
      # Audit fields
      t.references :created_by, foreign_key: { to_table: :users }
      t.references :updated_by, foreign_key: { to_table: :users }
      t.timestamps
      
      # Indexes
      t.index [:company_id, :sku], unique: true, where: "is_deleted = false"
      t.index [:company_id, :active]
      t.index [:company_id, :category_id]
      t.index :barcode
      t.index :manufacturer_part_no
      t.index :qb_item_id
      t.index [:company_id, :name], where: "is_deleted = false"
    end
  end
end
