# frozen_string_literal: true

# The factory PO (backlog E51): a purchase order for a home, built from the
# deal's LIVE Deal Sheet and linked to the deal. Its lines are the model and
# its factory options, not parts, so a line's part is optional on these.
# Receiving it records the home (serial number, into inventory, linked to the
# deal) and posts nothing: the cost reaches the books with the factory invoice.
class AddFactoryOrdersToPurchaseOrders < ActiveRecord::Migration[8.0]
  def change
    add_reference :purchase_orders, :deal, foreign_key: true
    add_column :purchase_orders, :kind, :string, null: false, default: 'parts' # parts | factory_home
    add_reference :purchase_orders, :deal_home_build, foreign_key: { on_delete: :nullify }
    add_reference :purchase_orders, :received_vehicle, foreign_key: { to_table: :vehicles }
    # The sheet's factory lines when the PO was written, to tell when the sheet changed since.
    add_column :purchase_orders, :sheet_snapshot, :jsonb, null: false, default: {}

    change_column_null :purchase_order_lines, :part_id, true
    add_reference :purchase_order_lines, :catalog_option, foreign_key: { on_delete: :nullify }
  end
end
