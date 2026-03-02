# frozen_string_literal: true

class CreateOptionCategories < ActiveRecord::Migration[8.0]
  def change
    create_table :option_categories do |t|
      t.references :floor_plan, null: false, foreign_key: true
      t.string :name, null: false
      t.text :description
      t.integer :display_order, default: 0
      t.boolean :is_required, default: false, null: false
      t.boolean :allow_multiple_selections, default: false, null: false

      t.timestamps
    end

    add_index :option_categories, [:floor_plan_id, :display_order]
  end
end
