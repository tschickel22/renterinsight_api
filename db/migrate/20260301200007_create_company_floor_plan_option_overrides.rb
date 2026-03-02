# frozen_string_literal: true

class CreateCompanyFloorPlanOptionOverrides < ActiveRecord::Migration[8.0]
  def change
    create_table :company_floor_plan_option_overrides do |t|
      t.references :company, null: false, foreign_key: true
      t.references :floor_plan_option, null: false, foreign_key: true
      t.decimal :dealer_cost, precision: 10, scale: 2
      t.decimal :retail_price, precision: 10, scale: 2
      t.boolean :is_hidden, default: false, null: false

      t.timestamps
    end

    add_index :company_floor_plan_option_overrides,
              [:company_id, :floor_plan_option_id],
              unique: true,
              name: 'idx_company_option_overrides_unique'
  end
end
