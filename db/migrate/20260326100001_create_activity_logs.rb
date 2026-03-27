# frozen_string_literal: true

class CreateActivityLogs < ActiveRecord::Migration[8.0]
  def change
    create_table :activity_logs do |t|
      t.bigint :company_id, null: false
      t.bigint :user_id
      t.string :trackable_type
      t.bigint :trackable_id
      t.bigint :account_id
      t.bigint :location_id
      t.string :action, null: false
      t.string :module_name, null: false
      t.string :entity_type_label
      t.string :description, null: false
      t.jsonb :changes_made, default: {}
      t.jsonb :metadata, default: {}
      t.string :ip_address

      t.timestamps
    end

    add_foreign_key :activity_logs, :companies

    # Main feed query
    add_index :activity_logs, [:company_id, :created_at]
    # My activity / user activity
    add_index :activity_logs, [:company_id, :user_id, :created_at]
    # Account rollup
    add_index :activity_logs, [:company_id, :account_id, :created_at]
    # RBAC location filtering
    add_index :activity_logs, [:company_id, :location_id, :created_at]
    # Entity detail tab
    add_index :activity_logs, [:trackable_type, :trackable_id]
    # Module filtering
    add_index :activity_logs, [:company_id, :module_name, :created_at]
    # Action type filtering
    add_index :activity_logs, :action
  end
end
