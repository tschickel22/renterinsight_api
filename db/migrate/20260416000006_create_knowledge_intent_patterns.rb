# frozen_string_literal: true

class CreateKnowledgeIntentPatterns < ActiveRecord::Migration[8.0]
  # intent_type values: navigate, create, search, report, help, explain, configure
  def change
    create_table :knowledge_intent_patterns do |t|
      t.string  :pattern,     null: false
      t.string  :intent_type, null: false
      t.string  :entity_key
      t.integer :priority,    null: false, default: 0
      t.timestamps
    end

    add_index :knowledge_intent_patterns, :intent_type
    add_index :knowledge_intent_patterns, :entity_key
    add_index :knowledge_intent_patterns, :priority, order: { priority: :desc }
  end
end
