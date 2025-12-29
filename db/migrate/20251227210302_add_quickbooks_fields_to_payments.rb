class AddQuickbooksFieldsToPayments < ActiveRecord::Migration[7.0]
  def change
    add_column :payments, :quickbooks_id, :string
    add_column :payments, :quickbooks_synced_at, :datetime
    
    add_index :payments, :quickbooks_id
  end
end
