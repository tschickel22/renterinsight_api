class AddCommissionsResourceToRbac < ActiveRecord::Migration[8.0]
  def up
    # Add commissions resource to RBAC system
    resource = Resource.find_or_create_by!(key: 'commissions') do |r|
      r.name = 'Commissions'
      r.description = 'Manage sales commissions and commission rules'
      r.category = 'operations'  # Must be: core, operations, or admin
      r.active = true
    end

    # Get all action IDs for CRUD + custom actions
    actions = {
      create: Action.find_or_create_by!(key: 'create') { |a| a.name = 'Create' },
      read: Action.find_or_create_by!(key: 'read') { |a| a.name = 'Read' },
      update: Action.find_or_create_by!(key: 'update') { |a| a.name = 'Update' },
      delete: Action.find_or_create_by!(key: 'delete') { |a| a.name = 'Delete' },
      approve: Action.find_or_create_by!(key: 'approve') { |a| a.name = 'Approve' },
      pay: Action.find_or_create_by!(key: 'pay') { |a| a.name = 'Mark as Paid' }
    }

    # Get scope (assuming 'all' scope exists)
    all_scope = Scope.find_or_create_by!(key: 'all') { |s| s.name = 'All' }

    # Seed default permissions for system roles
    # Platform Admin - full access
    if (role = Role.find_by(key: 'platform_admin', tier: 'platform'))
      actions.each do |_key, action|
        RolePermission.find_or_create_by!(
          role: role,
          resource: resource,
          action: action,
          scope: all_scope
        ) do |rp|
          rp.granted = true
        end
      end
    end

    # Company Admin - full access
    if (role = Role.find_by(key: 'company_admin', tier: 'company'))
      actions.each do |_key, action|
        RolePermission.find_or_create_by!(
          role: role,
          resource: resource,
          action: action,
          scope: all_scope
        ) do |rp|
          rp.granted = true
        end
      end
    end

    # Manager - can view, approve, and pay
    if (role = Role.find_by(key: 'manager', tier: 'company'))
      [:read, :approve, :pay].each do |action_key|
        RolePermission.find_or_create_by!(
          role: role,
          resource: resource,
          action: actions[action_key],
          scope: all_scope
        ) do |rp|
          rp.granted = true
        end
      end
    end

    # User - can only view
    if (role = Role.find_by(key: 'user', tier: 'company'))
      RolePermission.find_or_create_by!(
        role: role,
        resource: resource,
        action: actions[:read],
        scope: all_scope
      ) do |rp|
        rp.granted = true
      end
    end
  end

  def down
    resource = Resource.find_by(key: 'commissions')
    if resource
      RolePermission.where(resource: resource).destroy_all
      resource.destroy
    end
  end
end
