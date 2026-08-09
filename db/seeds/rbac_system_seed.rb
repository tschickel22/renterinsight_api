# frozen_string_literal: true

# RBAC System Seed Data
# 
# This file seeds the initial data for the RBAC system:
# - System Resources (what can be accessed)
# - System Actions (what can be done)
# - System Scopes (where access applies)
# - Platform Default Roles with Permissions
#
# Run with: rails db:seed or rails runner db/seeds/rbac_system_seed.rb

puts "🔐 Seeding RBAC System..."

# 1. Seed Resources
puts "\n📦 Seeding Resources..."
Resource.seed_defaults
puts "✅ Created #{Resource.count} resources"

# 2. Seed Actions
puts "\n⚡ Seeding Actions..."
Action.seed_defaults
puts "✅ Created #{Action.count} actions"

# 3. Seed Scopes
puts "\n🎯 Seeding Scopes..."
Scope.seed_defaults
puts "✅ Created #{Scope.count} scopes"

# 4. Seed Platform Default Roles with Permissions
puts "\n👥 Seeding Platform Default Roles..."
Role.seed_defaults
puts "✅ Created #{Role.system_roles.count} system roles"
puts "✅ Created #{RolePermission.count} role permissions"

# 4b. Reconcile roles against resources added since the first seed.
#
# OPT-IN ONLY. bin/render-build.sh runs `rails db:seed` on every deploy, and
# unlike everything above this, reconciling REWRITES permissions that live
# tenants are already using: it revokes the admin-tier resources from the
# shipped non-admin roles and asserts reads across every active role. Running
# that automatically would change what real users can see, in production,
# without anyone asking for it.
#
# Run it deliberately instead:
#   RBAC_RECONCILE=true bin/rails db:seed
#   bin/rails rbac:reconcile
if ENV['RBAC_RECONCILE'] == 'true'
  puts "\n🔁 Reconciling system role permissions..."
  before = RolePermission.count
  Role.reconcile_system_permissions!
  puts "✅ Added #{RolePermission.count - before} missing role permissions"
else
  puts "\n⏭  Skipping role reconciliation (set RBAC_RECONCILE=true to run it)"
end

# 5. Display Summary
puts "\n" + "="*80
puts "RBAC System Seeding Complete!"
puts "="*80
puts "\n📊 Summary:"
puts "   Resources: #{Resource.count}"
puts "   Actions: #{Action.count}"
puts "   Scopes: #{Scope.count}"
puts "   System Roles: #{Role.system_roles.count}"
puts "   Role Permissions: #{RolePermission.count}"

puts "\n🎉 Platform Default Roles:"
Role.system_roles.each do |role|
  permission_count = role.role_permissions.count
  puts "   - #{role.name} (#{role.tier}): #{permission_count} permissions"
end

puts "\n✨ Ready to use! Companies can now:"
puts "   1. Enable RBAC with: company.update!(use_rbac_system: true)"
puts "   2. Create custom roles via UI"
puts "   3. Assign roles to users"
puts "="*80
