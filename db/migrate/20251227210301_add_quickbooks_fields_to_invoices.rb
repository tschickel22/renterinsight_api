class AddQuickbooksFieldsToInvoices < ActiveRecord::Migration[7.0]
  def change
    add_column :invoices, :quickbooks_id, :string
    add_column :invoices, :quickbooks_synced_at, :datetime
    
    add_index :invoices, :quickbooks_id
  end
end
