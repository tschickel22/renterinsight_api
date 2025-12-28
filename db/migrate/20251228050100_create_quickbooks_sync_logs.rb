# frozen_string_literal: true

class CreateQuickbooksSyncLogs < ActiveRecord::Migration[8.0]
  def change
    return if table_exists?(:quickbooks_sync_logs)

    create_table :quickbooks_sync_logs do |t|
      t.references :company, null: false, foreign_key: true
      t.references :location, null: true, foreign_key: true
      
      # Sync details
      t.string :operation, null: false  # 'sync_to_qb', 'sync_from_qb', etc.
      t.string :entity_type, null: false  # 'inventory', 'customers', etc.
      t.integer :entity_id  # The ID of the record being synced (optional)
      t.string :sync_direction  # 'to_qb', 'from_qb', 'bidirectional'
      
      # Status tracking
      t.string :status, null: false, default: 'pending'  # 'pending', 'success', 'failed'
      t.text :error_message
      
      # Request/response data
      t.jsonb :request_data
      t.jsonb :response_data
      
      # Performance tracking
      t.integer :duration_ms
      t.datetime :started_at
      t.datetime :completed_at
      
      t.timestamps
    end
    
    # Indexes for common queries
    add_index :quickbooks_sync_logs, [:company_id, :created_at] unless index_exists?(:quickbooks_sync_logs, [:company_id, :created_at])
    add_index :quickbooks_sync_logs, [:company_id, :status] unless index_exists?(:quickbooks_sync_logs, [:company_id, :status])
    add_index :quickbooks_sync_logs, [:company_id, :entity_type] unless index_exists?(:quickbooks_sync_logs, [:company_id, :entity_type])
    add_index :quickbooks_sync_logs, [:location_id, :created_at] unless index_exists?(:quickbooks_sync_logs, [:location_id, :created_at])
  end
end
