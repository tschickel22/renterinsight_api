class AddDealsCostDetailsResource < ActiveRecord::Migration[8.0]
  def up
    # Create new resource for deals cost details (separate from inventory cost details)
    deals_cost_resource = Resource.create!(
      key: 'deals_cost_details',
      name: 'Deals (Cost Details)',
      description: 'View and edit unit cost, pack, reserves, margins, and gross profit on deals',
      category: 'operations',
      permission_groups: {
        'view_edit_costs' => {
          'name' => 'View & Edit Cost Details',
          'description' => 'View unit cost, pack amount, reserves, margins, and gross profit calculations',
          'group' => 'financial',
          'actions' => ['read', 'update']
        }
      }
    )

    # Find all relevant actions
    read_action = Action.find_by(key: 'read')
    update_action = Action.find_by(key: 'update')
    create_action = Action.find_by(key: 'create')
    delete_action = Action.find_by(key: 'delete')
    export_action = Action.find_by(key: 'export')

    return unless [read_action, update_action, create_action, delete_action, export_action].all?(&:present?)

    # Find all relevant scopes
    platform_scope = Scope.find_by(key: 'platform')
    company_scope = Scope.find_by(key: 'company')
    location_scope = Scope.find_by(key: 'own')

    return unless [platform_scope, company_scope, location_scope].all?(&:present?)

    # Find roles that should have access to cost details
    platform_admin = Role.find_by(tier: 'platform', key: 'platform_admin')
    company_admin = Role.find_by(tier: 'company', key: 'company_admin')
    finance_manager = Role.find_by(tier: 'company', key: 'finance_manager')

    roles_with_access = [platform_admin, company_admin, finance_manager].compact

    # Grant permissions to finance roles
    roles_with_access.each do |role|
      case role.tier
      when 'platform'
        # Platform admin: all actions, platform scope
        [read_action, update_action, create_action, delete_action, export_action].each do |action|
          RolePermission.find_or_create_by!(
            role: role,
            resource: deals_cost_resource,
            action: action,
            scope: platform_scope
          )
        end
      when 'company'
        # Company admin & finance manager: all actions, company + location scopes
        [read_action, update_action, create_action, delete_action, export_action].each do |action|
          RolePermission.find_or_create_by!(
            role: role,
            resource: deals_cost_resource,
            action: action,
            scope: company_scope
          )
          RolePermission.find_or_create_by!(
            role: role,
            resource: deals_cost_resource,
            action: action,
            scope: location_scope
          )
        end
      end
    end

    puts "✅ Created 'Deals (Cost Details)' resource"
    puts "✅ Granted permissions to: #{roles_with_access.map(&:name).join(', ')}"
  end

  def down
    # Remove the resource (will cascade delete role_permissions)
    resource = Resource.find_by(key: 'deals_cost_details')
    resource&.destroy
    
    puts "🗑️  Removed 'Deals (Cost Details)' resource"
  end
end
