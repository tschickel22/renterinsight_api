class AddSalesRepAndInventoryToInvoices < ActiveRecord::Migration[8.0]
  def change
    # Add sales rep tracking (defaults to current user)
    add_column :invoices, :sales_rep_id, :integer unless column_exists?(:invoices, :sales_rep_id)
    add_index :invoices, :sales_rep_id unless index_exists?(:invoices, :sales_rep_id)
    
    # Add inventory tracking to invoice_items (polymorphic)
    add_column :invoice_items, :itemable_type, :string unless column_exists?(:invoice_items, :itemable_type)
    add_column :invoice_items, :itemable_id, :integer unless column_exists?(:invoice_items, :itemable_id)
    add_index :invoice_items, [:itemable_type, :itemable_id] unless index_exists?(:invoice_items, [:itemable_type, :itemable_id])
    
    # Add commission type for custom commission module integration
    add_column :invoice_items, :commission_type, :string, default: 'full_commission' unless column_exists?(:invoice_items, :commission_type)
    
    # Add original quote reference for conversion tracking
    add_column :invoices, :quote_id, :integer unless column_exists?(:invoices, :quote_id)
    add_index :invoices, :quote_id unless index_exists?(:invoices, :quote_id)
  end
end

