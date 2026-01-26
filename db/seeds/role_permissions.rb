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
  
  permissions_config.each do |resource_key, action_keys|
    resource = resources[resource_key]
    next unless resource
    
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

# ===== COMPANY ADMINISTRATOR =====
puts "📋 Company Administrator"
config = resources.keys.map { |key| [key, ALL] }.to_h
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
  'calendar' => CRUD_MANAGE, 'reports' => READ_EXPORT, 'portal' => CRUD_MANAGE,
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
  
  'calendar' => CRUD, 'reports' => READ_ONLY, 'portal' => CRUD, 'dashboard' => READ_ONLY
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
  
  'calendar' => CRUD_MANAGE, 'reports' => READ_EXPORT, 'portal' => CRUD_MANAGE,
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
  
  'calendar' => CRUD, 'reports' => READ_EXPORT, 'portal' => CRUD, 'dashboard' => READ_ONLY
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
  
  'calendar' => ['create', 'read', 'update'], 'portal' => ['create', 'read', 'update'], 'dashboard' => READ_ONLY
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
  
  'calendar' => CRUD, 'dashboard' => READ_EXPORT, 'reports' => READ_EXPORT
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
  
  'calendar' => CRUD, 'dashboard' => READ_ONLY
}
grant_permissions(Role.find_by(key: 'crm_specialist'), resources, actions, scopes, config)

# ===== SERVICE TECHNICIAN =====
puts "📋 Service Technician"
config = {
  'service' => CRUD, 'parts' => CRUD, 'tasks' => CRUD, 'documents' => CRUD,
  'warranty_claims' => CRUD,
  
  'inventory' => READ_ONLY, 'crm' => READ_ONLY, 'suppliers' => READ_ONLY,
  'part_categories' => READ_ONLY, 'bins' => READ_ONLY,
  
  'calendar' => ['create', 'read', 'update']
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
  
  'calendar' => READ_ONLY, 'reports' => READ_EXPORT
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
  
  'calendar' => READ_ONLY, 'dashboard_finance' => READ_ONLY, 'reports' => READ_EXPORT
}
grant_permissions(Role.find_by(key: 'finance_staff'), resources, actions, scopes, config)

# ===== READ-ONLY USER =====
puts "📋 Read-Only User"
config = resources.keys.map { |key| [key, READ_ONLY] }.to_h
# Add export for reports/data
['reports', 'dashboard', 'inventory', 'crm', 'leads', 'deals', 'invoices'].each do |key|
  config[key] = READ_EXPORT if resources[key]
end
grant_permissions(Role.find_by(key: 'read_only'), resources, actions, scopes, config)

puts "✅ Role permissions seeded successfully!"
