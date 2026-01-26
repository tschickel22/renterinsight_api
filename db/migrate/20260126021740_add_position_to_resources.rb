class AddPositionToResources < ActiveRecord::Migration[7.0]
  def change
    add_column :resources, :position, :integer, default: 0
    add_index :resources, :position
  end
end
