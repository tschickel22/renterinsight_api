# frozen_string_literal: true

class CreateKnowledgeChangeQueue < ActiveRecord::Migration[8.0]
  # change_type values:  added, removed, modified, renamed
  # entity_type values:  module, feature, permission, route, ui_element
  # status values:       pending, approved, rejected, auto_applied
  def change
    create_table :knowledge_change_queue do |t|
      t.references :knowledge_snapshot, null: false, foreign_key: true, index: true
      t.string   :change_type, null: false
      t.string   :entity_type, null: false
      t.string   :entity_key,  null: false
      t.jsonb    :old_value
      t.jsonb    :new_value
      t.string   :status,      null: false, default: 'pending'
      t.references :reviewed_by, null: true, foreign_key: { to_table: :users }, index: true
      t.datetime :reviewed_at
      t.timestamps
    end

    add_index :knowledge_change_queue, :status
    add_index :knowledge_change_queue, :change_type
    add_index :knowledge_change_queue, :entity_type
    add_index :knowledge_change_queue, :entity_key
    add_index :knowledge_change_queue, [:entity_type, :entity_key]
  end
end
