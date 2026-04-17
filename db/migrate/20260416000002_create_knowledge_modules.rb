# frozen_string_literal: true

class CreateKnowledgeModules < ActiveRecord::Migration[8.0]
  def change
    create_table :knowledge_modules do |t|
      t.string  :key,         null: false
      t.string  :name,        null: false
      t.text    :description
      t.string  :icon
      t.string  :route
      t.integer :position,    null: false, default: 0
      t.boolean :is_active,   null: false, default: true
      t.timestamps
    end

    add_index :knowledge_modules, :key, unique: true
    add_index :knowledge_modules, [:is_active, :position]
  end
end
