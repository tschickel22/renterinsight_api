class AddAssignedToToDeals < ActiveRecord::Migration[8.0]
  def change
    add_column :deals, :assigned_to, :string
    add_index :deals, :assigned_to
  end
end
