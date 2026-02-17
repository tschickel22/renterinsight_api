# frozen_string_literal: true

class CreatePartnerApiTables < ActiveRecord::Migration[8.0]
  def change
    # ==================== API KEYS ====================
    create_table :api_keys do |t|
      t.bigint :company_id, null: false
      t.string :name, null: false
      t.string :key, null: false
      t.string :secret_digest, null: false
      t.jsonb :permissions, default: {}
      t.string :status, default: "active", null: false
      t.datetime :last_used_at
      t.bigint :request_count, default: 0, null: false
      t.integer :rate_limit, default: 1000, null: false
      t.bigint :created_by_user_id, null: false
      t.timestamps

      t.index :key, unique: true
      t.index :company_id
      t.index :created_by_user_id
      t.index :status
      t.index [:company_id, :status]
    end

    # ==================== WEBHOOK ENDPOINTS ====================
    create_table :webhook_endpoints do |t|
      t.bigint :company_id, null: false
      t.string :url, null: false
      t.jsonb :events, default: []
      t.string :secret, null: false
      t.string :status, default: "active", null: false
      t.datetime :last_triggered_at
      t.integer :failure_count, default: 0, null: false
      t.timestamps

      t.index :company_id
      t.index :status
      t.index [:company_id, :status]
    end

    # ==================== WEBHOOK DELIVERIES ====================
    create_table :webhook_deliveries do |t|
      t.bigint :webhook_endpoint_id, null: false
      t.string :event, null: false
      t.jsonb :payload, default: {}
      t.integer :response_code
      t.text :response_body
      t.datetime :delivered_at
      t.integer :attempts, default: 0, null: false
      t.timestamps

      t.index :webhook_endpoint_id
      t.index :event
      t.index [:webhook_endpoint_id, :event]
      t.index :delivered_at
    end
  end
end
