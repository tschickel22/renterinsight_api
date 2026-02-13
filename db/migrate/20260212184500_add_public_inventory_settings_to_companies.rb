class AddPublicInventorySettingsToCompanies < ActiveRecord::Migration[8.0]
  def change
    # Add public inventory token for secure access
    add_column :companies, :public_inventory_token, :string
    add_index :companies, :public_inventory_token, unique: true
    
    # Add JSONB column for public inventory settings
    add_column :companies, :public_inventory_settings, :jsonb, default: {}
    add_index :companies, :public_inventory_settings, using: :gin
  end
end
