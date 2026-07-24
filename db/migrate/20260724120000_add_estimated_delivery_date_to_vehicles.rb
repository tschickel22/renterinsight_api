# frozen_string_literal: true

class AddEstimatedDeliveryDateToVehicles < ActiveRecord::Migration[8.0]
  def change
    # Estimated delivery to lot — dealer's expected arrival date for ordered /
    # on-order inventory. Surfaced on the inventory form/detail and stock report.
    add_column :vehicles, :estimated_delivery_date, :date
  end
end
