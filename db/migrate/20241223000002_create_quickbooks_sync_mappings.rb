class CreateQuickbooksSyncMappings < ActiveRecord::Migration[8.0]
  def change
    # Tracks mapping between RenterInsight entities and QuickBooks entities
    create_table :quickbooks_sync_mappings do |t|
      t.references :company, null: false, foreign_key: true
      t.references :location, null: true, foreign_key: true # Location-specific QB instance
      
      # RenterInsight entity
      t.string :renter_insight_entity_type, null: false # 'Vehicle', 'Invoice', 'Contact', etc.
      t.bigint :renter_insight_entity_id, null: false
      
      # QuickBooks entity
      t.string :quickbooks_entity_type, null: false # 'Item', 'Invoice', 'Customer', etc.
      t.string :quickbooks_entity_id, null: false # QB's unique ID
      
      # Sync metadata
      t.string :sync_direction, default: 'bidirectional' # 'to_qb', 'from_qb', 'bidirectional'
      t.datetime :last_synced_at
      t.jsonb :last_sync_data # Store last known state for conflict detection
      t.string :sync_status, default: 'active' # 'active', 'error', 'disabled'
      t.text :sync_error_message
      t.integer :sync_error_count, default: 0
      
      t.timestamps
    end
    
    # Add indexes only if they don't exist
    unless index_exists?(:quickbooks_sync_mappings, [:company_id, :renter_insight_entity_type, :renter_insight_entity_id], name: 'idx_qb_sync_ri_entity')
      add_index :quickbooks_sync_mappings, [:company_id, :renter_insight_entity_type, :renter_insight_entity_id], 
                name: 'idx_qb_sync_ri_entity'
    end
    
    unless index_exists?(:quickbooks_sync_mappings, [:company_id, :quickbooks_entity_type, :quickbooks_entity_id], name: 'idx_qb_sync_qb_entity')
      add_index :quickbooks_sync_mappings, [:company_id, :quickbooks_entity_type, :quickbooks_entity_id],
                name: 'idx_qb_sync_qb_entity'
    end
    
    unless index_exists?(:quickbooks_sync_mappings, :location_id)
      add_index :quickbooks_sync_mappings, :location_id
    end
    
    unless index_exists?(:quickbooks_sync_mappings, :sync_status)
      add_index :quickbooks_sync_mappings, :sync_status
    end
  end
end
