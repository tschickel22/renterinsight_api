# frozen_string_literal: true

class CreateFloorPlanOptionApplicability < ActiveRecord::Migration[8.0]
  def change
    create_table :floor_plan_option_applicabilities do |t|
      t.references :floor_plan, null: false, foreign_key: true
      t.references :floor_plan_option, null: false, foreign_key: true

      t.boolean :is_default_for_model, default: false, null: false

      t.decimal :price_dealer_override, precision: 10, scale: 2
      t.decimal :price_retail_override, precision: 10, scale: 2

      t.timestamps
    end

    # t.references above already creates indexes on floor_plan_id and floor_plan_option_id
    # Only add the composite unique and the boolean index manually
    add_index :floor_plan_option_applicabilities,
              [:floor_plan_id, :floor_plan_option_id],
              unique: true,
              name: 'idx_fp_option_applicability_unique'

    add_index :floor_plan_option_applicabilities, :is_default_for_model
  end
end
