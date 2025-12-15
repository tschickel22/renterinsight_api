class AddOwnerIdToContacts < ActiveRecord::Migration[8.0]
  def change
    add_column :contacts, :owner_id, :integer
    add_index :contacts, :owner_id
  end
end
