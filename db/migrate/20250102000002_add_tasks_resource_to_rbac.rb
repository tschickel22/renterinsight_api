class AddTasksResourceToRbac < ActiveRecord::Migration[8.0]
  def up
    # Add tasks resource
    tasks_resource = Resource.find_or_create_by!(key: 'tasks') do |r|
      r.name = 'Tasks'
      r.description = 'Manage tasks and to-do items across all modules'
      r.category = 'operations'
      r.active = true
    end
    
    puts "✅ Created 'tasks' resource"
    
    # Automatically grant permissions to existing system roles
    grant_permissions_to_system_roles(tasks_resource)
  end
  
  def down
    # Remove tasks resource (cascade delete will handle permissions)
    Resource.find_by(key: 'tasks')&.destroy
    puts "❌ Removed 'tasks' resource"
  end
  
  private
  
  def grant_permissions_to_system_roles(tasks_resource)
    # Get scopes
    all_scope = Scope.find_by!(key: 'all')
    assigned_locations_scope = Scope.find_by!(key: 'assigned_locations')
    
    # Get actions
    all_actions = Action.all
    operational_actions = Action.where(key: %w[create read update delete export])
    staff_actions = Action.where(key: %w[create read update])
    read_action = Action.find_by!(key: 'read')
    
    # Company Admin - Full access
    company_admin = Role.system_roles.find_by(key: 'company_admin')
    if company_admin
      all_actions.each do |action|
        RolePermission.find_or_create_by!(
          role: company_admin,
          resource: tasks_resource,
          action: action,
          scope: all_scope,
          granted: true
        )
      end
      puts "  ✅ Granted full permissions to Company Administrator"
    end
    
    # Company Manager - Operational access at assigned locations
    company_manager = Role.system_roles.find_by(key: 'company_manager')
    if company_manager
      operational_actions.each do |action|
        RolePermission.find_or_create_by!(
          role: company_manager,
          resource: tasks_resource,
          action: action,
          scope: assigned_locations_scope,
          granted: true
        )
      end
      puts "  ✅ Granted operational permissions to Company Manager"
    end
    
    # Company Staff - Create/Read/Update at assigned locations
    company_staff = Role.system_roles.find_by(key: 'company_staff')
    if company_staff
      staff_actions.each do |action|
        RolePermission.find_or_create_by!(
          role: company_staff,
          resource: tasks_resource,
          action: action,
          scope: assigned_locations_scope,
          granted: true
        )
      end
      puts "  ✅ Granted staff permissions to Company Staff"
    end
    
    # Read-Only User - Read access everywhere
    company_read_only = Role.system_roles.find_by(key: 'company_read_only')
    if company_read_only
      RolePermission.find_or_create_by!(
        role: company_read_only,
        resource: tasks_resource,
        action: read_action,
        scope: all_scope,
        granted: true
      )
      puts "  ✅ Granted read-only permissions to Read-Only User"
    end
    
    # Location Admin - Full access at assigned locations
    location_admin = Role.system_roles.find_by(key: 'location_admin')
    if location_admin
      all_actions.each do |action|
        RolePermission.find_or_create_by!(
          role: location_admin,
          resource: tasks_resource,
          action: action,
          scope: assigned_locations_scope,
          granted: true
        )
      end
      puts "  ✅ Granted full permissions to Location Administrator"
    end
    
    # Location Manager - Operational access
    location_manager = Role.system_roles.find_by(key: 'location_manager')
    if location_manager
      operational_actions.each do |action|
        RolePermission.find_or_create_by!(
          role: location_manager,
          resource: tasks_resource,
          action: action,
          scope: assigned_locations_scope,
          granted: true
        )
      end
      puts "  ✅ Granted operational permissions to Location Manager"
    end
    
    # Location Staff - Create/Read/Update
    location_staff = Role.system_roles.find_by(key: 'location_staff')
    if location_staff
      staff_actions.each do |action|
        RolePermission.find_or_create_by!(
          role: location_staff,
          resource: tasks_resource,
          action: action,
          scope: assigned_locations_scope,
          granted: true
        )
      end
      puts "  ✅ Granted staff permissions to Location Staff"
    end
    
    # Specialized roles - Full access to tasks
    specialized_roles = %w[service_tech sales_rep finance_staff crm_specialist inventory_manager]
    specialized_roles.each do |role_key|
      role = Role.system_roles.find_by(key: role_key)
      next unless role
      
      operational_actions.each do |action|
        RolePermission.find_or_create_by!(
          role: role,
          resource: tasks_resource,
          action: action,
          scope: assigned_locations_scope,
          granted: true
        )
      end
      puts "  ✅ Granted operational permissions to #{role.name}"
    end
    
    puts "\n📊 Tasks Resource Summary:"
    puts "  Total Permissions Created: #{RolePermission.where(resource: tasks_resource).count}"
  end
end
