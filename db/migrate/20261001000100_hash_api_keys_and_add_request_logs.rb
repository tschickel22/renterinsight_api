# frozen_string_literal: true

# Partner API keys were stored in plaintext in api_keys.key and looked up with
# find_by(key:), while the UI told admins "only a masked preview is stored".
# This adds a SHA-256 digest plus a display preview and backfills both from the
# existing keys, so every live integration keeps working unchanged.
#
# The plaintext column is deliberately NOT cleared here. Render runs migrations
# while the previous release is still serving, and that release looks keys up
# by plaintext. Clearing it in the same deploy would 401 every Zapier and
# Facebook intake for the length of the rollout. A follow-up migration nulls
# the column once this release is live.
#
# api_request_logs is the per-request audit trail for key callers, and doubles
# as the rate-limit counter: the old counter lived in Rails.cache, which in
# production is per instance, so the hourly limit was never global.
class HashApiKeysAndAddRequestLogs < ActiveRecord::Migration[8.0]
  def up
    add_column :api_keys, :key_digest, :string
    add_column :api_keys, :key_preview, :string
    change_column_null :api_keys, :key, true

    execute <<~SQL
      UPDATE api_keys
      SET key_digest  = encode(sha256(convert_to(key, 'UTF8')), 'hex'),
          key_preview = left(key, 12) || '...' || right(key, 4)
      WHERE key IS NOT NULL
    SQL

    add_index :api_keys, :key_digest, unique: true

    create_table :api_request_logs do |t|
      t.bigint :api_key_id
      t.bigint :company_id
      t.string :http_method, null: false
      t.string :path, null: false
      t.integer :status, null: false
      t.integer :duration_ms
      t.string :ip_address
      t.string :user_agent
      t.datetime :created_at, null: false
    end
    add_index :api_request_logs, [:api_key_id, :created_at]
    add_index :api_request_logs, [:company_id, :created_at]
  end

  def down
    drop_table :api_request_logs
    remove_index :api_keys, :key_digest
    remove_column :api_keys, :key_preview
    remove_column :api_keys, :key_digest
  end
end
