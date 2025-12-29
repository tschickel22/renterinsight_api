class AddQuickbooksFieldsToVendors < ActiveRecord::Migration[7.0]
  def change
    if table_exists?(:vendors)
      add_column :vendors, :quickbooks_id, :string
      add_column :vendors, :quickbooks_synced_at, :datetime
      
      add_index :vendors, :quickbooks_id
    end
  end
end
