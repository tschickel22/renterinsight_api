class AddIsCorporateToLocations < ActiveRecord::Migration[8.0]
  def change
    add_column :locations, :is_corporate, :boolean, default: false, null: false
    add_index :locations, [:company_id, :is_corporate], where: "is_corporate = true", unique: true, name: 'index_locations_one_corporate_per_company'
  end
end
