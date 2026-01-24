# frozen_string_literal: true

class AddUseLocationAddressToVehicles < ActiveRecord::Migration[8.0]
  def change
    unless column_exists?(:vehicles, :use_location_address)
      add_column :vehicles, :use_location_address, :boolean, default: false
      add_index :vehicles, :use_location_address
    end
  end
end
