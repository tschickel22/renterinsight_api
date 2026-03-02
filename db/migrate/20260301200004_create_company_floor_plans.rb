# frozen_string_literal: true

class CreateCompanyFloorPlans < ActiveRecord::Migration[8.0]
  def change
    create_table :company_floor_plans do |t|
      t.references :company, null: false, foreign_key: true
      t.references :floor_plan, null: false, foreign_key: true
      t.boolean :is_visible, default: true, null: false
      t.decimal :dealer_cost, precision: 10, scale: 2
      t.decimal :retail_price, precision: 10, scale: 2
      t.string :markup_type
      t.decimal :markup_value, precision: 10, scale: 2
      t.string :custom_name
      t.text :custom_description
      t.integer :display_order, default: 0

      t.timestamps
    end

    add_index :company_floor_plans, [:company_id, :floor_plan_id], unique: true
    add_index :company_floor_plans, :is_visible
  end
end
