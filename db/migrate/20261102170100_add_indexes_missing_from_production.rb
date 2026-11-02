# frozen_string_literal: true

# schema.rb has listed these for months; production never got them.
class AddIndexesMissingFromProduction < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def change
    add_index :service_tickets, :assigned_to, algorithm: :concurrently, if_not_exists: true
    add_index :inventory_transactions, :purchase_order_line_id, algorithm: :concurrently, if_not_exists: true
  end
end
