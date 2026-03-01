class AddVehicleIdToLeads < ActiveRecord::Migration[8.0]
  def change
    add_reference :leads, :vehicle, null: true, foreign_key: true
  end
end
