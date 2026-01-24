# frozen_string_literal: true

class AddDealParticipantsToDeals < ActiveRecord::Migration[8.0]
  def change
    # Add role-specific participant fields to deals
    add_column :deals, :sales_manager_id, :bigint
    add_column :deals, :finance_manager_id, :bigint
    add_column :deals, :desk_manager_id, :bigint
    add_column :deals, :secondary_salesperson_id, :bigint
    
    # Add foreign keys
    add_foreign_key :deals, :users, column: :sales_manager_id
    add_foreign_key :deals, :users, column: :finance_manager_id
    add_foreign_key :deals, :users, column: :desk_manager_id
    add_foreign_key :deals, :users, column: :secondary_salesperson_id
    
    # Add indexes for performance
    add_index :deals, :sales_manager_id
    add_index :deals, :finance_manager_id
    add_index :deals, :desk_manager_id
    add_index :deals, :secondary_salesperson_id
  end
end
