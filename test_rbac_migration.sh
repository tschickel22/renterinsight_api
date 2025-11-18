#!/bin/bash

echo "🧪 Testing RBAC Migration - Phase 1A"
echo "===================================="
echo ""

cd /home/tschi/src/renterinsight_api

echo "📍 Current directory: $(pwd)"
echo ""

echo "1️⃣ Checking current migration status..."
bin/rails db:version
echo ""

echo "2️⃣ Running RBAC migration..."
bin/rails db:migrate VERSION=20251117000001
echo ""

echo "3️⃣ Verifying tables were created..."
bin/rails runner "
puts '✅ Resources table: ' + (ActiveRecord::Base.connection.table_exists?('resources') ? 'EXISTS' : 'MISSING')
puts '✅ Actions table: ' + (ActiveRecord::Base.connection.table_exists?('actions') ? 'EXISTS' : 'MISSING')
puts '✅ Scopes table: ' + (ActiveRecord::Base.connection.table_exists?('scopes') ? 'EXISTS' : 'MISSING')
puts '✅ Roles table: ' + (ActiveRecord::Base.connection.table_exists?('roles') ? 'EXISTS' : 'MISSING')
puts '✅ Role Permissions table: ' + (ActiveRecord::Base.connection.table_exists?('role_permissions') ? 'EXISTS' : 'MISSING')
puts '✅ User Role Assignments table: ' + (ActiveRecord::Base.connection.table_exists?('user_role_assignments') ? 'EXISTS' : 'MISSING')
puts ''
puts '✅ Company.use_rbac_system column: ' + (Company.column_names.include?('use_rbac_system') ? 'EXISTS' : 'MISSING')
"
echo ""

echo "4️⃣ Running seed data..."
bin/rails runner db/seeds/rbac_system_seed.rb
echo ""

echo "5️⃣ Verifying seed data..."
bin/rails runner "
puts '📊 Seed Data Results:'
puts '   Resources: ' + Resource.count.to_s
puts '   Actions: ' + Action.count.to_s
puts '   Scopes: ' + Scope.count.to_s
puts '   System Roles: ' + Role.system_roles.count.to_s
puts '   Role Permissions: ' + RolePermission.count.to_s
puts ''
puts '👥 Platform Default Roles:'
Role.system_roles.order(:tier, :name).each do |role|
  puts '   - ' + role.name + ' (' + role.tier + '): ' + role.role_permissions.count.to_s + ' permissions'
end
"
echo ""

echo "6️⃣ Testing permission logic..."
bin/rails runner "
# Test Company Admin role
company_admin = Role.find_by(key: 'company_admin', tier: 'company')
if company_admin
  puts '✅ Company Admin role found'
  puts '   - Total permissions: ' + company_admin.role_permissions.granted.count.to_s
  
  # Test a few specific permissions
  has_inventory_create = company_admin.has_permission?('inventory', 'create', 'all')
  has_users_manage = company_admin.has_permission?('users', 'manage', 'all')
  has_reports_read = company_admin.has_permission?('reports', 'read', 'all')
  
  puts '   - Can create inventory: ' + has_inventory_create.to_s
  puts '   - Can manage users: ' + has_users_manage.to_s
  puts '   - Can read reports: ' + has_reports_read.to_s
else
  puts '❌ Company Admin role NOT found'
end

# Test Location Staff role
location_staff = Role.find_by(key: 'location_staff', tier: 'location')
if location_staff
  puts ''
  puts '✅ Location Staff role found'
  puts '   - Total permissions: ' + location_staff.role_permissions.granted.count.to_s
else
  puts '❌ Location Staff role NOT found'
end
"
echo ""

echo "✅ Migration test complete!"
echo "===================================="
