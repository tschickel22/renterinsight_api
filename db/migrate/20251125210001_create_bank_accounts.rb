# frozen_string_literal: true

class CreateBankAccounts < ActiveRecord::Migration[8.0]
  def up
    return if table_exists?(:bank_accounts)
    
    create_table :bank_accounts do |t|
      # Associations
      t.bigint :company_id, null: false
      t.bigint :location_id, null: false # Previously "property_id" in old system
      
      # Account identification
      t.string :account_purpose, null: false # 'operating' or 'deposit'
      t.string :account_type, null: false # 'checking' or 'savings'
      t.string :bank_name
      
      # Account details (encrypted in production)
      t.string :routing_number, null: false
      t.string :account_number, null: false
      t.string :account_holder_name
      
      # Zego integration
      t.string :external_id # Zego PayeeId
      
      # Status
      t.boolean :is_active, default: true, null: false
      t.boolean :is_verified, default: false, null: false
      t.datetime :verified_at
      
      # Audit
      t.boolean :is_deleted, default: false
      t.datetime :deleted_at
      t.string :created_by
      t.string :updated_by
      
      t.timestamps
    end
    
    # Indexes
    add_index :bank_accounts, :company_id
    add_index :bank_accounts, :location_id
    add_index :bank_accounts, [:company_id, :location_id]
    add_index :bank_accounts, [:location_id, :account_purpose]
    add_index :bank_accounts, :external_id
    add_index :bank_accounts, :is_deleted
    
    # Foreign keys
    add_foreign_key :bank_accounts, :companies, column: :company_id
    add_foreign_key :bank_accounts, :locations, column: :location_id
  end

  def down
    drop_table :bank_accounts if table_exists?(:bank_accounts)
  end
end
