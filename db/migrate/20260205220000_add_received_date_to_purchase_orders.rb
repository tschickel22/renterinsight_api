# frozen_string_literal: true

class AddReceivedDateToPurchaseOrders < ActiveRecord::Migration[8.0]
  def change
    add_column :purchase_orders, :received_date, :datetime unless column_exists?(:purchase_orders, :received_date)
    add_index :purchase_orders, :received_date unless index_exists?(:purchase_orders, :received_date)
  end
end
