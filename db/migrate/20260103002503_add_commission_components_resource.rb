# frozen_string_literal: true

class AddCommissionComponentsResource < ActiveRecord::Migration[8.0]
  def up
    # Add commission_components resource if it doesn't exist
    unless Resource.exists?(key: 'commission_components')
      Resource.create!(
        key: 'commission_components',
        name: 'Commission Components',
        description: 'Manage commission plan components and rules',
        category: 'operations',
        active: true,
        permission_ui_type: 'standard_crud'
      )
      
      Rails.logger.info "✅ Created 'commission_components' RBAC resource"
    end
  end
  
  def down
    Resource.find_by(key: 'commission_components')&.destroy
  end
end
