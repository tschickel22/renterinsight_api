# frozen_string_literal: true

class CreateQuickbooksConnections < ActiveRecord::Migration[8.0]
  def change
    return if table_exists?(:quickbooks_connections)

    create_table :quickbooks_connections do |t|
      t.references :company, null: false, foreign_key: true
      t.string :realm_id
      t.string :company_name
      t.text :access_token
      t.text :refresh_token
      t.datetime :token_expires_at
      t.datetime :refresh_token_expires_at
      t.string :status, default: 'disconnected'
      t.text :error_message
      t.boolean :sync_enabled, default: false
      t.boolean :auto_sync_enabled, default: false
      t.string :auto_sync_interval, default: 'daily'
      t.date :sync_start_date
      t.boolean :initial_sync_complete, default: false
      t.string :sync_mode, default: 'create_only'
      t.datetime :last_sync_at
      t.timestamps
    end

    add_index :quickbooks_connections, :company_id, unique: true, name: 'idx_qbo_connections_company_unique'
  end
end
