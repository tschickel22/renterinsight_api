# frozen_string_literal: true

# One row per record an AI app changed through the MCP connector, with the
# values before and after, so an admin (or the person) can undo it: one change
# at a time, or everything a runaway connection did in the last few hours.
# Also the count behind the per-person change limits.
class CreateMcpChanges < ActiveRecord::Migration[8.0]
  def change
    create_table :mcp_changes do |t|
      t.bigint :mcp_tool_call_id
      t.bigint :oauth_grant_id
      t.bigint :user_id, null: false
      t.bigint :company_id, null: false
      t.string :action, null: false # created | updated
      t.string :record_type, null: false
      t.bigint :record_id, null: false
      t.jsonb :before, null: false, default: {}
      t.jsonb :after, null: false, default: {}
      t.datetime :undone_at
      t.bigint :undone_by_user_id
      t.string :undo_note
      t.datetime :created_at, null: false
    end
    add_index :mcp_changes, [:company_id, :created_at]
    add_index :mcp_changes, [:user_id, :created_at]
    add_index :mcp_changes, [:oauth_grant_id, :created_at]
    add_index :mcp_changes, :mcp_tool_call_id
  end
end
