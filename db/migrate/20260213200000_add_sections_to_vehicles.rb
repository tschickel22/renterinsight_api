class AddSectionsToVehicles < ActiveRecord::Migration[8.0]
  def change
    add_column :vehicles, :sections, :integer
  end
end
