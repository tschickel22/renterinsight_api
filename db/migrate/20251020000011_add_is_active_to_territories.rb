class AddIsActiveToTerritories < ActiveRecord::Migration[8.0]
  def change
    add_column :territories, :is_active, :boolean, default: true, null: false
  end
end
