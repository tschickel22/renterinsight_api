class AddQuickbooksFieldsToContacts < ActiveRecord::Migration[7.0]
  def change
    add_column :contacts, :quickbooks_id, :string
    add_column :contacts, :quickbooks_synced_at, :datetime
    
    add_index :contacts, :quickbooks_id
  end
end
