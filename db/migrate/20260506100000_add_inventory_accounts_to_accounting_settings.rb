# frozen_string_literal: true

class AddInventoryAccountsToAccountingSettings < ActiveRecord::Migration[8.0]
  def change
    add_reference :accounting_settings, :default_parts_inventory_account,
                  foreign_key: { to_table: :chart_of_accounts },
                  null: true
    add_reference :accounting_settings, :default_vehicle_inventory_account,
                  foreign_key: { to_table: :chart_of_accounts },
                  null: true

    add_column :accounting_settings, :auto_post_purchase_orders, :boolean, default: true
    add_column :accounting_settings, :auto_post_parts_usage, :boolean, default: true
  end
end
