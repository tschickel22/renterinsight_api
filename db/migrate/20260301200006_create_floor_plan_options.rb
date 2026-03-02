# frozen_string_literal: true

class CreateFloorPlanOptions < ActiveRecord::Migration[8.0]
  def change
    create_table :floor_plan_options do |t|
      t.references :option_category, null: false, foreign_key: true
      t.string :name, null: false
      t.text :description
      t.string :image_url
      t.decimal :price_impact_low, precision: 10, scale: 2
      t.decimal :price_impact_high, precision: 10, scale: 2
      t.jsonb :compatibility_rules, default: {}
      t.integer :display_order, default: 0
      t.boolean :is_default, default: false, null: false

      t.timestamps
    end

    add_index :floor_plan_options, [:option_category_id, :display_order]
    add_index :floor_plan_options, :is_default
  end
end
