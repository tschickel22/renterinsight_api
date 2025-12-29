class AddQuickbooksFieldsToPurchases < ActiveRecord::Migration[7.0]
  def change
    if table_exists?(:purchases)
      add_column :purchases, :quickbooks_id, :string
      add_column :purchases, :quickbooks_synced_at, :datetime
      
      add_index :purchases, :quickbooks_id
    end
  end
end
