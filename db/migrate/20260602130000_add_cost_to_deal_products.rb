class AddCostToDealProducts < ActiveRecord::Migration[8.0]
  def change
    add_column :deal_products, :cost, :decimal, precision: 12, scale: 2, default: 0
  end
end
