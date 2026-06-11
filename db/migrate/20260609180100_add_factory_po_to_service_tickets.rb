# frozen_string_literal: true

# Adds an optional Factory PO reference to service tickets. Used to tie a ticket
# (often warranty-related) back to a factory purchase order. Free-text.
class AddFactoryPoToServiceTickets < ActiveRecord::Migration[8.0]
  def change
    add_column :service_tickets, :factory_po, :string unless column_exists?(:service_tickets, :factory_po)
  end
end
