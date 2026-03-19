# frozen_string_literal: true

class CreateOfflineSyncLogs < ActiveRecord::Migration[8.0]
  def change
    create_table :offline_sync_logs do |t|
      t.references :company, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :device_id
      t.string :sync_status, default: 'pending'
      t.integer :total_operations, default: 0
      t.integer :successful_operations, default: 0
      t.integer :failed_operations, default: 0
      t.jsonb :operations, default: []
      t.jsonb :errors, default: []
      t.datetime :started_at
      t.datetime :completed_at

      t.timestamps
    end

    add_index :offline_sync_logs, [:company_id, :user_id]
    add_index :offline_sync_logs, :device_id
  end
end
