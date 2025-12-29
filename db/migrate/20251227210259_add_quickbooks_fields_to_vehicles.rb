class AddQuickbooksFieldsToVehicles < ActiveRecord::Migration[7.0]
  def change
    add_column :vehicles, :quickbooks_id, :string
    add_column :vehicles, :quickbooks_synced_at, :datetime
    
    add_index :vehicles, :quickbooks_id
  end
end
