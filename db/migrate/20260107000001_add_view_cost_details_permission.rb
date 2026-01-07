class AddViewCostDetailsPermission < ActiveRecord::Migration[8.0]
  def up
    # Find the deals resource
    deals_resource = Resource.find_by(key: 'deals')
    return unless deals_resource

    # Find the read action
    read_action = Action.find_by(key: 'read')
    return unless read_action

    # Find all scopes (we'll need all of them)
    platform_scope = Scope.find_by(key: 'platform')
    company_scope = Scope.find_by(key: 'company')
    location_scope = Scope.find_by(key: 'own')

    return unless [platform_scope, company_scope, location_scope].all?(&:present?)

    # Find roles that should have this permission
    platform_admin = Role.find_by(tier: 'platform', key: 'platform_admin')
    company_admin = Role.find_by(tier: 'company', key: 'company_admin')
    finance_manager = Role.find_by(tier: 'company', key: 'finance_manager')

    # Create permission entry in permission_groups for view_cost_details
    deals_resource.update!(
      permission_groups: deals_resource.permission_groups.merge({
        'view_cost_details' => {
          'name' => 'View Cost Details',
          'description' => 'View dealer cost, margins, pack, and gross profit calculations',
          'group' => 'financial',
          'actions' => ['read']
        }
      })
    )

    # Grant permission to platform admin (all scopes)
    if platform_admin
      [platform_scope, company_scope, location_scope].each do |scope|
        RolePermission.find_or_create_by!(
          role: platform_admin,
          resource: deals_resource,
          action: read_action,
          scope: scope
        ) do |rp|
          rp.granted = true
        end
      end
    end

    # Grant permission to company admin (company and location scopes)
    if company_admin
      [company_scope, location_scope].each do |scope|
        RolePermission.find_or_create_by!(
          role: company_admin,
          resource: deals_resource,
          action: read_action,
          scope: scope
        ) do |rp|
          rp.granted = true
        end
      end
    end

    # Grant permission to finance manager (company and location scopes)
    if finance_manager
      [company_scope, location_scope].each do |scope|
        RolePermission.find_or_create_by!(
          role: finance_manager,
          resource: deals_resource,
          action: read_action,
          scope: scope
        ) do |rp|
          rp.granted = true
        end
      end
    end

    puts "✅ Added view_cost_details permission to deals resource"
  end

  def down
    deals_resource = Resource.find_by(key: 'deals')
    return unless deals_resource

    # Remove from permission_groups
    new_groups = deals_resource.permission_groups.except('view_cost_details')
    deals_resource.update!(permission_groups: new_groups)

    puts "✅ Removed view_cost_details permission from deals resource"
  end
end
