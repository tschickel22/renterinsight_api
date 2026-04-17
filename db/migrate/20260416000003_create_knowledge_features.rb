# frozen_string_literal: true

class CreateKnowledgeFeatures < ActiveRecord::Migration[8.0]
  def change
    create_table :knowledge_features do |t|
      t.references :knowledge_module, null: false, foreign_key: true, index: true
      t.string  :key,             null: false
      t.string  :name,            null: false
      t.text    :description
      t.string  :route
      t.string  :ui_selector
      t.string  :permission_key
      t.integer :position,        null: false, default: 0
      t.timestamps
    end

    add_index :knowledge_features, [:knowledge_module_id, :key], unique: true
    add_index :knowledge_features, :permission_key
  end
end
