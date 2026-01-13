# frozen_string_literal: true

class AddCommissionPlansToRbac < ActiveRecord::Migration[8.0]
  def up
    # Create commission_plans resource
    commission_plans_resource = Resource.find_or_create_by!(key: 'commission_plans') do |r|
      r.name = 'Commission Plans'
      r.description = 'Manage commission plan templates and assignments'
      r.category = 'operations'
      r.active = true
      r.permission_ui_type = 'standard_crud'
    end
    
    # Grant to finance roles
    finance_roles = Role.where(key: ['finance_manager', 'company_admin', 'platform_admin'])
    
    finance_roles.each do |role|
      # Full CRUD access
      %w[create read update delete].each do |action_key|
        action = Action.find_by(key: action_key)
        scope = Scope.find_by(key: role.tier == 'platform' ? 'all' : 'company')
        
        next unless action && scope
        
        RolePermission.find_or_create_by!(
          role: role,
          resource: commission_plans_resource,
          action: action,
          scope: scope,
          granted: true
        )
      end
    end
    
    puts "✅ Added commission_plans resource to RBAC"
  end
  
  def down
    commission_plans_resource = Resource.find_by(key: 'commission_plans')
    
    if commission_plans_resource
      RolePermission.where(resource: commission_plans_resource).destroy_all
      commission_plans_resource.destroy
    end
    
    puts "✅ Removed commission_plans resource from RBAC"
  end
end
