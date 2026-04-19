# frozen_string_literal: true

# Snapshots of the scanned knowledge state (modules/features/permissions) taken
# during CI/CD. A snapshot is compared to the previous one to detect drift.
class CreateKnowledgeSnapshots < ActiveRecord::Migration[8.0]
  def change
    create_table :knowledge_snapshots do |t|
      t.datetime :snapshot_at,      null: false
      t.string   :modules_hash,     null: false
      t.integer  :features_count,   null: false, default: 0
      t.jsonb    :changes_detected, null: false, default: {}
      t.timestamps
    end

    add_index :knowledge_snapshots, :snapshot_at
    add_index :knowledge_snapshots, :modules_hash
  end
end
