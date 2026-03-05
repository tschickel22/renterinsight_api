# frozen_string_literal: true

class AddSpecialDiscountToVehicles < ActiveRecord::Migration[8.0]
  def change
    add_column :vehicles, :special_discount_enabled, :boolean, default: false unless column_exists?(:vehicles, :special_discount_enabled)
    add_column :vehicles, :discount_type, :string unless column_exists?(:vehicles, :discount_type)
    add_column :vehicles, :discount_value, :decimal, precision: 12, scale: 2 unless column_exists?(:vehicles, :discount_value)
    add_column :vehicles, :discounted_price, :decimal, precision: 12, scale: 2 unless column_exists?(:vehicles, :discounted_price)
  end
end
