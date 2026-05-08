# frozen_string_literal: true

class AddFloorPlanDefaultsToAccountingSettings < ActiveRecord::Migration[8.0]
  def change
    add_column :accounting_settings, :floor_plan_tracking_enabled, :boolean, default: false, null: false unless column_exists?(:accounting_settings, :floor_plan_tracking_enabled)
    add_column :accounting_settings, :default_floor_plan_rate, :decimal, precision: 8, scale: 5 unless column_exists?(:accounting_settings, :default_floor_plan_rate)
    add_column :accounting_settings, :default_floor_plan_lender, :string unless column_exists?(:accounting_settings, :default_floor_plan_lender)
  end
end
