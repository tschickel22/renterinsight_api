class SetDefaultTypeFieldForTerritories < ActiveRecord::Migration[8.0]
  def up
    # Set default type_field for any existing territories that don't have one
    Territory.where(type_field: nil).update_all(type_field: 'geographic')
  end

  def down
    # This migration is safe to reverse - it won't remove the type_field values
  end
end
