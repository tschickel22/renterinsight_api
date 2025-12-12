class AddHomeInfoToServiceTickets < ActiveRecord::Migration[8.0]
  def change
    add_column :service_tickets, :home_info, :text unless column_exists?(:service_tickets, :home_info)
  end
end
