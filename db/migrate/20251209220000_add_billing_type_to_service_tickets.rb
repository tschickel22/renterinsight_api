# frozen_string_literal: true

class AddBillingTypeToServiceTickets < ActiveRecord::Migration[8.0]
  def change
    # Track which line items are warranty vs customer-pay
    # Structure: [{ index: 0, type: 'part', billing_type: 'warranty', manufacturer_id: 5 }]
    add_column :service_tickets, :line_item_billing, :jsonb, default: []
    
    # Track if ticket was created via portal
    add_column :service_tickets, :portal_user_id, :bigint
    add_column :service_tickets, :is_portal_created, :boolean, default: false
    add_column :service_tickets, :portal_notes, :text
    
    add_index :service_tickets, :portal_user_id
    add_index :service_tickets, :is_portal_created
  end
end
