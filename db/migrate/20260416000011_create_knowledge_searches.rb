# frozen_string_literal: true

# Analytics event log for the smart-help search box.
# Append-only; `created_at` only (no updated_at).
class CreateKnowledgeSearches < ActiveRecord::Migration[8.0]
  def change
    create_table :knowledge_searches do |t|
      t.references :user, null: true, foreign_key: true, index: true
      t.string  :query,           null: false
      t.string  :intent_detected
      t.integer :result_count,    null: false, default: 0
      t.string  :action_taken
      t.datetime :created_at,     null: false
    end

    add_index :knowledge_searches, :intent_detected
    add_index :knowledge_searches, :created_at
  end
end
