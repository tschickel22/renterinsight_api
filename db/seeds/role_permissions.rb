# frozen_string_literal: true

# Role Permissions Seeding
# Run with: bin/rails runner "load 'db/seeds/role_permissions.rb'"

puts "🌱 Seeding role permissions..."

resources = Resource.all.index_by(&:key)
actions = Action.all.index_by(&:key)
scopes = Scope.all.index_by(&:key)

def grant_permissions(role, resources, actions, scopes, permissions_config)
  return unless role
  
  # Clear existing
  RolePermission.where(role: role).destroy_all
  
  permissions = []
  
  permissions_config.each do |resource_key, action_config|
    resource = resources[resource_key]
    next unless resource
    
    # Handle both simple arrays and hash configs
    if action_config.is_a?(Hash) && action_config[:specialized]
      # Specialized permissions with custom scopes (e.g., calendar)
      action_config[:permissions].each do |perm|
        action = actions[perm[:action]]
        scope = scopes[perm[:scope]]
        next unless action && scope
        
        permissions << {
          resource_id: resource.id,
          action_id: action.id,
          scope_id: scope.id
        }
      end
    else
      # Standard permissions with 'all' scope
      action_keys = action_config.is_a?(Array) ? action_config : [action_config]
      action_keys.each do |action_key|
        action = actions[action_key]
        scope = scopes['all']
        next unless action && scope
        
        permissions << {
          resource_id: resource.id,
          action_id: action.id,
          scope_id: scope.id
        }
      end
    end
  end
  
  # Batch create
  permissions.each { |p| RolePermission.create!(role: role, **p, granted: true) }
  
  puts "  ✅ #{role.name}: #{permissions.count} permissions"
end

# ALL ACTIONS shorthand
ALL = ['create', 'read', 'update', 'delete', 'export', 'import', 'assign', 'manage', 'view_pii', 'approve']
CRUD = ['create', 'read', 'update', 'delete']
CRUD_EXPORT = ['create', 'read', 'update', 'delete', 'export']
CRUD_MANAGE = ['create', 'read', 'update', 'delete', 'export', 'manage']
READ_ONLY = ['read']
READ_EXPORT = ['read', 'export']

# Calendar permission templates
CALENDAR_FULL = {
  specialized: true,
  permissions: [
    { action: 'read', scope: 'own' },                    # View own calendar
    { action: 'read', scope: 'assigned_locations' },     # View team at assigned locations
    { action: 'read', scope: 'all' },                    # View all company calendars (using 'all' scope)
    { action: 'create', scope: 'all' },                  # Create events
    { action: 'update', scope: 'all' },                  # Update/reschedule
    { action: 'delete', scope: 'all' },                  # Delete events
    { action: 'manage', scope: 'all' }                   # Full calendar management
  ]
}

CALENDAR_OWN_AND_TEAM = {
  specialized: true,
  permissions: [
    { action: 'read', scope: 'own' },                    # View own calendar
    { action: 'read', scope: 'assigned_locations' },     # View team at assigned locations
    { action: 'create', scope: 'all' },                  # Create events
    { action: 'update', scope: 'all' },                  # Update/reschedule
    { action: 'delete', scope: 'all' }                   # Delete events
  ]
}

CALENDAR_OWN_ONLY = {
  specialized: true,
  permissions: [
    { action: 'read', scope: 'own' },                    # View own calendar only
    { action: 'create', scope: 'all' },                  # Create events
    { action: 'update', scope: 'all' }                   # Update/reschedule
  ]
}

CALENDAR_READ_ONLY = {
  specialized: true,
  permissions: [
    { action: 'read', scope: 'own' }                     # View own calendar only
  ]
}

# ===== COMPANY ADMINISTRATOR =====
puts "📋 Company Administrator"
config = resources.keys.map { |key| [key, ALL] }.to_h
config['calendar'] = CALENDAR_FULL  # Override with specialized calendar permissions
grant_permissions(Role.find_by(key: 'company_admin'), resources, actions, scopes, config)

# ===== COMPANY MANAGER =====
puts "📋 Company Manager"
config = {
  # Operations - Full control
  'inventory' => CRUD_MANAGE, 'crm' => CRUD_MANAGE, 'leads' => CRUD_MANAGE, 'deals' => CRUD_MANAGE,
  'service' => CRUD_MANAGE, 'finance' => CRUD_MANAGE, 'communications' => CRUD_MANAGE,
  'listings' => CRUD_MANAGE, 'products' => CRUD_MANAGE, 'tasks' => CRUD_MANAGE, 'documents' => CRUD_MANAGE,
  'invoices' => CRUD_EXPORT, 'loans' => CRUD_EXPORT,
  
  # Parts & Inventory
  'parts' => CRUD_MANAGE, 'bins' => CRUD_MANAGE, 'suppliers' => CRUD_MANAGE,
  'part_categories' => CRUD_MANAGE, 'purchase_orders' => CRUD_MANAGE,
  
  # Warranty
  'warranty_claims' => CRUD_MANAGE, 'manufacturer_ar' => CRUD_MANAGE, 'manufacturers' => CRUD_MANAGE,
  
  # Cost Details
  'inventory_cost_details' => READ_EXPORT, 'deals_cost_details' => READ_EXPORT,
  
  # Commissions
  'commissions' => CRUD_MANAGE, 'commission_plans' => CRUD_MANAGE,
  'commission_components' => CRUD_MANAGE, 'commission_payments' => CRUD_MANAGE,
  
  # Admin - Read only
  'company_settings' => READ_ONLY, 'users' => READ_ONLY, 'locations' => READ_ONLY, 'branding' => READ_ONLY,
  
  # Core
  'calendar' => CALENDAR_FULL, 'reports' => READ_EXPORT, 'portal' => CRUD_MANAGE,
  'dashboard' => READ_ONLY, 'dashboard_company_wide' => READ_ONLY, 'dashboard_finance' => READ_ONLY
}
grant_permissions(Role.find_by(key: 'company_manager'), resources, actions, scopes, config)

# ===== COMPANY STAFF =====
puts "📋 Company Staff"
config = {
  'inventory' => CRUD, 'crm' => CRUD, 'leads' => CRUD, 'deals' => CRUD, 'service' => CRUD,
  'communications' => CRUD, 'listings' => CRUD, 'products' => CRUD, 'tasks' => CRUD, 'documents' => CRUD,
  'parts' => CRUD, 'suppliers' => ['read', 'update'], 'warranty_claims' => CRUD,
  'invoices' => ['read', 'update'], 'finance' => ['read', 'update'],
  
  'company_settings' => READ_ONLY, 'users' => READ_ONLY, 'locations' => READ_ONLY, 'branding' => READ_ONLY,
  'purchase_orders' => READ_ONLY, 'bins' => READ_ONLY, 'part_categories' => READ_ONLY,
  
  'calendar' => CALENDAR_OWN_AND_TEAM, 'reports' => READ_ONLY, 'portal' => CRUD, 'dashboard' => READ_ONLY
}
grant_permissions(Role.find_by(key: 'company_staff'), resources, actions, scopes, config)

# ===== LOCATION ADMINISTRATOR =====
puts "📋 Location Administrator"
config = {
  'inventory' => CRUD_MANAGE, 'crm' => CRUD_MANAGE, 'leads' => CRUD_MANAGE, 'deals' => CRUD_MANAGE,
  'service' => CRUD_MANAGE, 'finance' => CRUD_MANAGE, 'communications' => CRUD_MANAGE,
  'listings' => CRUD_MANAGE, 'products' => CRUD_MANAGE, 'tasks' => CRUD_MANAGE, 'documents' => CRUD_MANAGE,
  'invoices' => CRUD_EXPORT, 'loans' => CRUD_EXPORT,
  
  'parts' => CRUD_MANAGE, 'bins' => CRUD_MANAGE, 'suppliers' => CRUD_MANAGE,
  'part_categories' => CRUD_MANAGE, 'purchase_orders' => CRUD_MANAGE,
  
  'warranty_claims' => CRUD_MANAGE, 'manufacturer_ar' => CRUD_MANAGE, 'manufacturers' => CRUD_MANAGE,
  'commissions' => CRUD_EXPORT,
  
  'users' => ['create', 'read', 'update', 'assign'],
  'company_settings' => READ_ONLY, 'locations' => ['read', 'update'], 'branding' => ['read', 'update'],
  
  'calendar' => CALENDAR_FULL, 'reports' => READ_EXPORT, 'portal' => CRUD_MANAGE,
  'dashboard' => READ_ONLY, 'dashboard_finance' => READ_ONLY
}
grant_permissions(Role.find_by(key: 'location_admin'), resources, actions, scopes, config)

# ===== LOCATION MANAGER =====
puts "📋 Location Manager"
config = {
  'inventory' => CRUD_EXPORT, 'crm' => CRUD_EXPORT, 'leads' => CRUD_EXPORT, 'deals' => CRUD_EXPORT,
  'service' => CRUD_EXPORT, 'communications' => CRUD_EXPORT, 'listings' => CRUD_EXPORT,
  'products' => CRUD_EXPORT, 'tasks' => CRUD_EXPORT, 'documents' => CRUD_EXPORT,
  'parts' => CRUD_EXPORT, 'suppliers' => ['read', 'update'], 'warranty_claims' => CRUD_EXPORT,
  'invoices' => ['read', 'update'],
  
  'company_settings' => READ_ONLY, 'users' => READ_ONLY, 'locations' => READ_ONLY, 'branding' => READ_ONLY,
  'finance' => READ_ONLY, 'bins' => READ_ONLY, 'part_categories' => READ_ONLY, 'purchase_orders' => READ_ONLY,
  
  'calendar' => CALENDAR_OWN_AND_TEAM, 'reports' => READ_EXPORT, 'portal' => CRUD, 'dashboard' => READ_ONLY
}
grant_permissions(Role.find_by(key: 'location_manager'), resources, actions, scopes, config)

# ===== LOCATION STAFF =====
puts "📋 Location Staff"
config = {
  'inventory' => ['create', 'read', 'update'], 'crm' => ['create', 'read', 'update'],
  'leads' => ['create', 'read', 'update'], 'deals' => ['create', 'read', 'update'],
  'service' => ['create', 'read', 'update'], 'tasks' => ['create', 'read', 'update'],
  'documents' => ['create', 'read', 'update'], 'parts' => ['create', 'read', 'update'],
  'warranty_claims' => ['create', 'read', 'update'],
  
  'company_settings' => READ_ONLY, 'users' => READ_ONLY, 'locations' => READ_ONLY, 'branding' => READ_ONLY,
  'finance' => READ_ONLY, 'invoices' => READ_ONLY, 'communications' => READ_ONLY,
  'listings' => READ_ONLY, 'products' => READ_ONLY, 'suppliers' => READ_ONLY,
  'bins' => READ_ONLY, 'part_categories' => READ_ONLY, 'purchase_orders' => READ_ONLY,
  
  'calendar' => CALENDAR_OWN_ONLY, 'portal' => ['create', 'read', 'update'], 'dashboard' => READ_ONLY
}
grant_permissions(Role.find_by(key: 'location_staff'), resources, actions, scopes, config)

# ===== SALES REPRESENTATIVE =====
puts "📋 Sales Representative"
config = {
  # Full sales pipeline
  'leads' => CRUD_EXPORT, 'deals' => CRUD_EXPORT, 'crm' => CRUD_EXPORT,
  'communications' => CRUD_EXPORT, 'listings' => CRUD_EXPORT, 'products' => CRUD_EXPORT,
  'inventory' => CRUD_EXPORT, 'parts' => CRUD_EXPORT, 'quotes' => CRUD_EXPORT,
  'documents' => CRUD,
  
  # Read-only supporting
  'company_settings' => READ_ONLY, 'users' => READ_ONLY, 'locations' => READ_ONLY,
  'suppliers' => READ_ONLY, 'part_categories' => READ_ONLY, 'invoices' => READ_ONLY,
  'tasks' => ['create', 'read', 'update'],
  
  'calendar' => CALENDAR_OWN_ONLY, 'dashboard' => READ_EXPORT, 'reports' => READ_EXPORT
}
grant_permissions(Role.find_by(key: 'sales_rep'), resources, actions, scopes, config)

# ===== CRM SPECIALIST =====
puts "📋 CRM Specialist"
config = {
  'leads' => CRUD_EXPORT + ['assign'], 'crm' => CRUD_EXPORT + ['assign'],
  'deals' => CRUD_EXPORT + ['assign'], 'communications' => CRUD_EXPORT,
  'tasks' => CRUD_EXPORT, 'documents' => CRUD_EXPORT,
  
  'company_settings' => READ_ONLY, 'users' => READ_ONLY, 'locations' => READ_ONLY,
  'products' => READ_ONLY, 'listings' => READ_ONLY,
  
  'calendar' => CALENDAR_OWN_ONLY, 'dashboard' => READ_ONLY
}
grant_permissions(Role.find_by(key: 'crm_specialist'), resources, actions, scopes, config)

# ===== SERVICE TECHNICIAN =====
puts "📋 Service Technician"
config = {
  'service' => CRUD, 'parts' => CRUD, 'tasks' => CRUD, 'documents' => CRUD,
  'warranty_claims' => CRUD,
  
  'inventory' => READ_ONLY, 'crm' => READ_ONLY, 'suppliers' => READ_ONLY,
  'part_categories' => READ_ONLY, 'bins' => READ_ONLY,
  
  'calendar' => CALENDAR_OWN_ONLY
}
grant_permissions(Role.find_by(key: 'service_tech'), resources, actions, scopes, config)

# ===== INVENTORY MANAGER =====
puts "📋 Inventory Manager"
config = {
  'inventory' => CRUD_MANAGE, 'parts' => CRUD_MANAGE, 'bins' => CRUD_MANAGE,
  'suppliers' => CRUD_MANAGE, 'part_categories' => CRUD_MANAGE, 'purchase_orders' => CRUD_MANAGE,
  'products' => CRUD_MANAGE, 'manufacturers' => CRUD_MANAGE, 'manufacturer_ar' => CRUD_MANAGE,
  'inventory_cost_details' => READ_EXPORT,
  
  'company_settings' => READ_ONLY, 'users' => READ_ONLY, 'locations' => READ_ONLY,
  'deals' => READ_ONLY, 'service' => READ_ONLY, 'warranty_claims' => READ_ONLY,
  
  'calendar' => CALENDAR_READ_ONLY, 'reports' => READ_EXPORT
}
grant_permissions(Role.find_by(key: 'inventory_manager'), resources, actions, scopes, config)

# ===== FINANCE STAFF =====
puts "📋 Finance Staff"
config = {
  'finance' => CRUD_MANAGE + ['approve'], 'invoices' => CRUD_MANAGE + ['approve'],
  'loans' => CRUD_MANAGE + ['approve'], 'commissions' => CRUD_MANAGE,
  'commission_payments' => CRUD_MANAGE + ['approve'],
  
  'company_settings' => READ_ONLY, 'users' => READ_ONLY, 'locations' => READ_ONLY,
  'crm' => READ_ONLY, 'leads' => READ_ONLY, 'deals' => READ_ONLY,
  'inventory' => READ_ONLY, 'service' => READ_ONLY,
  
  'calendar' => CALENDAR_READ_ONLY, 'dashboard_finance' => READ_ONLY, 'reports' => READ_EXPORT
}
grant_permissions(Role.find_by(key: 'finance_staff'), resources, actions, scopes, config)

# ===== READ-ONLY USER =====
puts "📋 Read-Only User"
config = resources.keys.map { |key| [key, READ_ONLY] }.to_h
config['calendar'] = CALENDAR_READ_ONLY  # Override with specialized calendar permissions
# Add export for reports/data
['reports', 'dashboard', 'inventory', 'crm', 'leads', 'deals', 'invoices'].each do |key|
  config[key] = READ_EXPORT if resources[key]
end
grant_permissions(Role.find_by(key: 'read_only'), resources, actions, scopes, config)

puts "✅ Role permissions seeded successfully!"
