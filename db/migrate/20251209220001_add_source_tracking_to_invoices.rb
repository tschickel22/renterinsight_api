# frozen_string_literal: true

class AddSourceTrackingToInvoices < ActiveRecord::Migration[8.0]
  def change
    # Polymorphic association to source (ServiceTicket, WarrantyClaim, etc)
    add_column :invoices, :source_type, :string
    add_column :invoices, :source_id, :bigint
    
    # Categorize invoice type
    add_column :invoices, :billing_category, :string # 'customer', 'warranty', 'internal'
    
    # For warranty invoices to manufacturers
    add_column :invoices, :recipient_type, :string # 'Account', 'Manufacturer'
    add_column :invoices, :recipient_id, :bigint
    
    add_index :invoices, [:source_type, :source_id]
    add_index :invoices, :billing_category
    add_index :invoices, [:recipient_type, :recipient_id]
  end
end
