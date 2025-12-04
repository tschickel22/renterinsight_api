# frozen_string_literal: true

class AddWarrantyFieldsToServiceTickets < ActiveRecord::Migration[8.0]
  def change
    add_column :service_tickets, :is_warranty_suspected, :boolean, default: false, null: false
    add_column :service_tickets, :is_warranty_confirmed, :boolean, default: false, null: false
    add_column :service_tickets, :warranty_claim_id, :bigint
    
    # Add foreign key
    add_foreign_key :service_tickets, :warranty_claims, on_delete: :nullify
    
    # Add indexes
    add_index :service_tickets, :is_warranty_suspected
    add_index :service_tickets, :is_warranty_confirmed
    add_index :service_tickets, :warranty_claim_id
    add_index :service_tickets, [:company_id, :is_warranty_confirmed]
  end
end
