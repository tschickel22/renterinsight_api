# frozen_string_literal: true

class AddQuickbooksScopeAndLocationFields < ActiveRecord::Migration[8.0]
  def change
    # Add scope to companies to determine if QB is company-wide or per-location
    unless column_exists?(:companies, :quickbooks_scope)
      add_column :companies, :quickbooks_scope, :string, default: 'company', null: false
      add_index :companies, :quickbooks_scope
    end
    
    # Add QuickBooks fields to locations for location-level integration (if not already present)
    add_column :locations, :quickbooks_realm_id, :string unless column_exists?(:locations, :quickbooks_realm_id)
    add_column :locations, :quickbooks_access_token_encrypted, :text unless column_exists?(:locations, :quickbooks_access_token_encrypted)
    add_column :locations, :quickbooks_refresh_token_encrypted, :text unless column_exists?(:locations, :quickbooks_refresh_token_encrypted)
    add_column :locations, :quickbooks_token_expires_at, :datetime unless column_exists?(:locations, :quickbooks_token_expires_at)
    add_column :locations, :quickbooks_connected_at, :datetime unless column_exists?(:locations, :quickbooks_connected_at)
    add_column :locations, :quickbooks_last_sync_at, :datetime unless column_exists?(:locations, :quickbooks_last_sync_at)
    add_column :locations, :quickbooks_sync_enabled, :boolean, default: false unless column_exists?(:locations, :quickbooks_sync_enabled)
    
    # Add indexes for finding locations with QB enabled (if not already present)
    add_index :locations, :quickbooks_sync_enabled unless index_exists?(:locations, :quickbooks_sync_enabled)
    add_index :locations, :quickbooks_realm_id unless index_exists?(:locations, :quickbooks_realm_id)
  end
end
