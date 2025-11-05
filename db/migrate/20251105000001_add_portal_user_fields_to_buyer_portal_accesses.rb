class AddPortalUserFieldsToBuyerPortalAccesses < ActiveRecord::Migration[7.0]
  def change
    add_column :buyer_portal_accesses, :first_name, :string
    add_column :buyer_portal_accesses, :last_name, :string
  end
end
