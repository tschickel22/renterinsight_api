# frozen_string_literal: true

class AddFloorPlanFieldsToVehicles < ActiveRecord::Migration[8.0]
  def change
    add_column :vehicles, :floor_plan_amount, :decimal, precision: 15, scale: 2 unless column_exists?(:vehicles, :floor_plan_amount)
    add_column :vehicles, :floor_plan_rate, :decimal, precision: 8, scale: 5 unless column_exists?(:vehicles, :floor_plan_rate)
    add_column :vehicles, :floor_plan_start_date, :date unless column_exists?(:vehicles, :floor_plan_start_date)
    add_column :vehicles, :floor_plan_accrued_interest, :decimal, precision: 15, scale: 2, default: 0 unless column_exists?(:vehicles, :floor_plan_accrued_interest)
    add_column :vehicles, :days_on_floor_plan, :integer, default: 0 unless column_exists?(:vehicles, :days_on_floor_plan)
    add_column :vehicles, :floor_plan_curtailed_at, :date unless column_exists?(:vehicles, :floor_plan_curtailed_at)
    add_column :vehicles, :floor_plan_lender, :string unless column_exists?(:vehicles, :floor_plan_lender)
  end
end
