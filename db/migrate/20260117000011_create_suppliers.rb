# frozen_string_literal: true

class CreateSuppliers < ActiveRecord::Migration[8.0]
  def change
    # Drop any orphaned indexes from previous failed attempts
    execute "DROP INDEX IF EXISTS index_suppliers_on_company_id" rescue nil
    execute "DROP INDEX IF EXISTS index_suppliers_on_created_by_id" rescue nil
    execute "DROP INDEX IF EXISTS index_suppliers_on_updated_by_id" rescue nil
    execute "DROP INDEX IF EXISTS index_suppliers_on_company_id_and_name" rescue nil
    execute "DROP INDEX IF EXISTS index_suppliers_on_company_id_and_code" rescue nil
    execute "DROP INDEX IF EXISTS index_suppliers_on_company_id_and_active" rescue nil
    execute "DROP INDEX IF EXISTS index_suppliers_on_qb_vendor_id" rescue nil
    
    return if table_exists?(:suppliers)
    
    create_table :suppliers do |t|
      t.references :company, null: false, foreign_key: true
      
      # Basic info
      t.string :name, null: false
      t.string :code # Short code like "SUP-001"
      t.string :contact_name
      t.string :email
      t.string :phone
      t.string :website
      
      # Address
      t.string :address_line1
      t.string :address_line2
      t.string :city
      t.string :state
      t.string :zip_code
      t.string :country, default: 'US'
      
      # Business details
      t.string :tax_id # EIN or Tax ID
      t.text :notes
      t.string :payment_terms # "Net 30", "COD", etc.
      t.integer :default_lead_time_days
      
      # QuickBooks integration
      t.string :qb_vendor_id
      
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
      
      t.index [:company_id, :name], where: "is_deleted = false"
      t.index [:company_id, :code], unique: true, where: "code IS NOT NULL AND is_deleted = false"
      t.index [:company_id, :active]
      t.index :qb_vendor_id
    end
  end
end
