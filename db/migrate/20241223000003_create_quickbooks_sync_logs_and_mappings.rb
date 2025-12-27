class CreateQuickbooksSyncLogsAndMappings < ActiveRecord::Migration[8.0]
  def change
    # Detailed sync operation logs
    create_table :quickbooks_sync_logs do |t|
      t.references :company, null: false, foreign_key: true
      t.references :location, null: true, foreign_key: true
      t.references :quickbooks_sync_mapping, null: true, foreign_key: true
      
      t.string :operation, null: false # 'create', 'update', 'delete', 'sync'
      t.string :entity_type, null: false
      t.bigint :entity_id
      t.string :sync_direction # 'to_qb', 'from_qb'
      
      t.string :status, default: 'pending' # 'pending', 'success', 'error', 'skipped'
      t.text :error_message
      t.jsonb :request_data
      t.jsonb :response_data
      
      t.float :duration_ms
      t.datetime :started_at
      t.datetime :completed_at
      
      t.timestamps
    end
    
    add_index :quickbooks_sync_logs, [:company_id, :created_at]
    add_index :quickbooks_sync_logs, [:location_id, :created_at]
    add_index :quickbooks_sync_logs, :status
    add_index :quickbooks_sync_logs, :entity_type
    
    # Customizable field mappings (for advanced configurations)
    create_table :quickbooks_field_mappings do |t|
      t.references :company, null: false, foreign_key: true
      t.references :location, null: true, foreign_key: true
      
      t.string :entity_type, null: false # 'vehicle', 'invoice', 'contact'
      t.string :renter_insight_field, null: false
      t.string :quickbooks_field, null: false
      t.string :mapping_type, default: 'direct' # 'direct', 'calculated', 'custom'
      t.text :transformation_logic # Ruby code or formula for calculated mappings
      
      t.boolean :enabled, default: true
      t.integer :priority, default: 0 # For ordering when multiple mappings exist
      
      t.timestamps
    end
    
    add_index :quickbooks_field_mappings, [:company_id, :entity_type]
    add_index :quickbooks_field_mappings, [:location_id, :entity_type]
  end
end
