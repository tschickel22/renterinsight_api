class AddOwnerIdToLeads < ActiveRecord::Migration[8.0]
  def change
    add_column :leads, :owner_id, :integer
    add_index :leads, :owner_id
  end
end
