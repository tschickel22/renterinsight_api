# frozen_string_literal: true

class AddMissingColumnsToAccounts < ActiveRecord::Migration[8.0]
  def change
    # Add missing columns for account information
    add_column :accounts, :account_type, :string
    add_column :accounts, :website, :string
    add_column :accounts, :industry, :string
    add_column :accounts, :rating, :string
    add_column :accounts, :ownership, :string
    add_column :accounts, :annual_revenue, :decimal, precision: 15, scale: 2
    add_column :accounts, :employee_count, :integer
    add_column :accounts, :description, :text
    add_column :accounts, :notes, :text
    
    # Billing Address
    add_column :accounts, :billing_street, :string
    add_column :accounts, :billing_city, :string
    add_column :accounts, :billing_state, :string
    add_column :accounts, :billing_postal_code, :string
    add_column :accounts, :billing_country, :string
    
    # Shipping Address
    add_column :accounts, :shipping_street, :string
    add_column :accounts, :shipping_city, :string
    add_column :accounts, :shipping_state, :string
    add_column :accounts, :shipping_postal_code, :string
    add_column :accounts, :shipping_country, :string
    
    # Relations
    add_column :accounts, :parent_account_id, :bigint
    add_column :accounts, :source_id, :bigint
    add_column :accounts, :owner_id, :bigint
    
    # System fields
    add_column :accounts, :account_number, :string
    add_column :accounts, :converted_date, :datetime
    add_column :accounts, :last_activity_date, :datetime
    add_column :accounts, :is_deleted, :boolean, default: false, null: false
    add_column :accounts, :deleted_at, :datetime
    
    # Add indexes for performance
    add_index :accounts, :account_type
    add_index :accounts, :rating
    add_index :accounts, :status
    add_index :accounts, :source_id
    add_index :accounts, :owner_id
    add_index :accounts, :parent_account_id
    add_index :accounts, :account_number, unique: true
    add_index :accounts, :is_deleted
    
    # Add foreign keys
    add_foreign_key :accounts, :accounts, column: :parent_account_id
    add_foreign_key :accounts, :sources
    add_foreign_key :accounts, :users, column: :owner_id
  end
end
