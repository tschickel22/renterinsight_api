class AddQuickbooksIntegration < ActiveRecord::Migration[8.0]
  def change
    # Add QuickBooks connection tracking to companies and locations
    add_column :companies, :quickbooks_realm_id, :string # QB company ID
    add_column :companies, :quickbooks_connected_at, :datetime
    add_column :companies, :quickbooks_access_token_encrypted, :text
    add_column :companies, :quickbooks_refresh_token_encrypted, :text
    add_column :companies, :quickbooks_token_expires_at, :datetime
    add_column :companies, :quickbooks_last_sync_at, :datetime
    add_column :companies, :quickbooks_sync_enabled, :boolean, default: false
    
    add_column :locations, :quickbooks_realm_id, :string # Location-specific QB company (optional)
    add_column :locations, :quickbooks_connected_at, :datetime
    add_column :locations, :quickbooks_access_token_encrypted, :text
    add_column :locations, :quickbooks_refresh_token_encrypted, :text
    add_column :locations, :quickbooks_token_expires_at, :datetime
    add_column :locations, :quickbooks_last_sync_at, :datetime
    add_column :locations, :quickbooks_sync_enabled, :boolean, default: false
    
    # Platform-level QB settings (will be stored in settings table)
    # These will include:
    # - qb_client_id
    # - qb_client_secret (encrypted)
    # - qb_environment (sandbox/production)
    # - qb_default_mappings
    
    add_index :companies, :quickbooks_realm_id
    add_index :locations, :quickbooks_realm_id
  end
end
