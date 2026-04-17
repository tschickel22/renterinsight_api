# frozen_string_literal: true

class CreateTours < ActiveRecord::Migration[8.0]
  # trigger_type values: manual, auto_on_first_visit, on_action, scheduled
  def change
    create_table :tours do |t|
      t.references :knowledge_module, null: true, foreign_key: true, index: true
      t.string  :key,          null: false
      t.string  :name,         null: false
      t.text    :description
      t.string  :trigger_type, null: false, default: 'manual'
      t.boolean :is_active,    null: false, default: true
      t.integer :position,     null: false, default: 0
      t.timestamps
    end

    add_index :tours, :key
    add_index :tours, [:knowledge_module_id, :key], unique: true
    add_index :tours, [:is_active, :position]
  end
end
