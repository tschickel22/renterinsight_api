class AddOwnerIdToDeals < ActiveRecord::Migration[8.0]
  def change
    add_column :deals, :owner_id, :integer
    add_index :deals, :owner_id
  end
end
