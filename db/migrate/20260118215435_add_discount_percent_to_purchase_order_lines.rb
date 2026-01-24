class AddDiscountPercentToPurchaseOrderLines < ActiveRecord::Migration[8.0]
  def change
    add_column :purchase_order_lines, :discount_percent, :decimal, precision: 5, scale: 2, default: 0.0
  end
end
