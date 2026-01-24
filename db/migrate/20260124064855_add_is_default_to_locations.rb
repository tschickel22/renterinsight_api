class AddIsDefaultToLocations < ActiveRecord::Migration[8.0]
  def up
    # Add the column with default false
    add_column :locations, :is_default, :boolean, default: false, null: false
    
    # Set the first location for each company as default
    # This handles existing companies that have locations
    execute <<-SQL
      UPDATE locations
      SET is_default = true
      WHERE id IN (
        SELECT DISTINCT ON (company_id) id
        FROM locations
        WHERE is_deleted = false
        ORDER BY company_id, created_at ASC
      )
    SQL
    
    # Add index for performance
    add_index :locations, [:company_id, :is_default], name: 'index_locations_on_company_id_and_is_default'
  end
  
  def down
    remove_index :locations, name: 'index_locations_on_company_id_and_is_default'
    remove_column :locations, :is_default
  end
end
