# frozen_string_literal: true

class AddIsDeletedAndCompanyNameToContacts < ActiveRecord::Migration[8.0]
  def change
    # Add is_deleted for soft delete functionality
    add_column :contacts, :is_deleted, :boolean, default: false, null: false unless column_exists?(:contacts, :is_deleted)
    
    # Add company_name from QuickBooks customers
    add_column :contacts, :company_name, :string unless column_exists?(:contacts, :company_name)
    
    # Add index on is_deleted for query performance
    add_index :contacts, :is_deleted unless index_exists?(:contacts, :is_deleted)
  end
end
