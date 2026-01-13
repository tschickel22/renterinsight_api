class AddCustomPermissionsToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :custom_permissions, :jsonb, default: []
    add_index :users, :custom_permissions, using: :gin
    
    # Backfill default financial permissions for existing roles
    reversible do |dir|
      dir.up do
        # Company admins get all financial permissions
        User.where(role: 'company_administrator').find_each do |user|
          user.update_column(:custom_permissions, [
            'inventory.view_cost',
            'inventory.edit_cost',
            'deals.view_financials',
            'deals.edit_financials',
            'commissions.view_all',
            'commissions.view_components'
          ])
        end
        
        # General managers get view-only
        User.where(role: 'general_manager').find_each do |user|
          user.update_column(:custom_permissions, [
            'inventory.view_cost',
            'deals.view_financials',
            'commissions.view_all'
          ])
        end
      end
    end
  end
end
