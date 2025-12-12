class AddPortalVisibleToServiceTickets < ActiveRecord::Migration[8.0]
  def change
    add_column :service_tickets, :portal_visible, :boolean, default: true, null: false unless column_exists?(:service_tickets, :portal_visible)
    add_index :service_tickets, :portal_visible unless index_exists?(:service_tickets, :portal_visible)
  end
end
