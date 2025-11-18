#!/usr/bin/env ruby
# frozen_string_literal: true

# RBAC System Verification Script
#
# Run with: bin/rails runner scripts/verify_rbac.rb
#
# Checks:
# 1. Database schema is correct
# 2. All required columns exist
# 3. All models are properly configured
# 4. Seeds are loaded

puts "\n╔════════════════════════════════════════════════════════╗"
puts "║       RBAC SYSTEM VERIFICATION                        ║"
puts "╚════════════════════════════════════════════════════════╝\n"

checks_passed = 0
checks_failed = 0
errors = []

def check(description)
  print "Checking: #{description}... "
  result = yield
  if result
    puts "✅ PASS"
    return true
  else
    puts "❌ FAIL"
    return false
  end
rescue StandardError => e
  puts "❌ ERROR: #{e.message}"
  return false
end

# ============================================================
# DATABASE SCHEMA CHECKS
# ============================================================
puts "\n=== Database Schema ==="

if check("resources table exists") { ActiveRecord::Base.connection.table_exists?('resources') }
  checks_passed += 1
else
  checks_failed += 1
  errors << "Resources table missing - run bin/rails db:migrate"
end

if check("actions table exists") { ActiveRecord::Base.connection.table_exists?('actions') }
  checks_passed += 1
else
  checks_failed += 1
  errors << "Actions table missing - run bin/rails db:migrate"
end

if check("scopes table exists") { ActiveRecord::Base.connection.table_exists?('scopes') }
  checks_passed += 1
else
  checks_failed += 1
  errors << "Scopes table missing - run bin/rails db:migrate"
end

if check("roles table exists") { ActiveRecord::Base.connection.table_exists?('roles') }
  checks_passed += 1
else
  checks_failed += 1
  errors << "Roles table missing - run bin/rails db:migrate"
end

if check("role_permissions table exists") { ActiveRecord::Base.connection.table_exists?('role_permissions') }
  checks_passed += 1
else
  checks_failed += 1
  errors << "RolePermissions table missing - run bin/rails db:migrate"
end

if check("user_role_assignments table exists") { ActiveRecord::Base.connection.table_exists?('user_role_assignments') }
  checks_passed += 1
else
  checks_failed += 1
  errors << "UserRoleAssignments table missing - run bin/rails db:migrate"
end

# ============================================================
# COLUMN CHECKS
# ============================================================
puts "\n=== Critical Columns ==="

if check("companies.use_rbac_system exists") { 
  ActiveRecord::Base.connection.column_exists?(:companies, :use_rbac_system) 
}
  checks_passed += 1
else
  checks_failed += 1
  errors << "companies.use_rbac_system missing - run bin/rails db:migrate"
end

if check("user_role_assignments.company_id exists") { 
  ActiveRecord::Base.connection.column_exists?(:user_role_assignments, :company_id) 
}
  checks_passed += 1
else
  checks_failed += 1
  errors << "user_role_assignments.company_id missing - run bin/rails db:migrate:up VERSION=20251117000002"
end

if check("user_role_assignments.user_id exists") { 
  ActiveRecord::Base.connection.column_exists?(:user_role_assignments, :user_id) 
}
  checks_passed += 1
else
  checks_failed += 1
  errors << "user_role_assignments.user_id missing - schema error"
end

if check("user_role_assignments.role_id exists") { 
  ActiveRecord::Base.connection.column_exists?(:user_role_assignments, :role_id) 
}
  checks_passed += 1
else
  checks_failed += 1
  errors << "user_role_assignments.role_id missing - schema error"
end

# ============================================================
# MODEL CHECKS
# ============================================================
puts "\n=== Model Configuration ==="

if check("User model has user_role_assignments association") { 
  User.reflect_on_association(:user_role_assignments).present? 
}
  checks_passed += 1
else
  checks_failed += 1
  errors << "User model missing user_role_assignments association"
end

if check("User model has roles association") { 
  User.reflect_on_association(:roles).present? 
}
  checks_passed += 1
else
  checks_failed += 1
  errors << "User model missing roles association"
end

if check("Company model has roles association") { 
  Company.reflect_on_association(:roles).present? 
}
  checks_passed += 1
else
  checks_failed += 1
  errors << "Company model missing roles association"
end

if check("Role model defined") { defined?(Role) }
  checks_passed += 1
else
  checks_failed += 1
  errors << "Role model not loaded - check app/models/role.rb"
end

if check("PermissionService defined") { defined?(PermissionService) }
  checks_passed += 1
else
  checks_failed += 1
  errors << "PermissionService not loaded - check app/services/permission_service.rb"
end

if check("RbacMigrationService defined") { defined?(RbacMigrationService) }
  checks_passed += 1
else
  checks_failed += 1
  errors << "RbacMigrationService not loaded - check app/services/rbac_migration_service.rb"
end

# ============================================================
# SEED DATA CHECKS
# ============================================================
puts "\n=== Seed Data ==="

if check("System roles seeded") { Role.system_roles.count >= 7 }
  checks_passed += 1
else
  checks_failed += 1
  errors << "System roles not seeded - run bin/rails rbac:seed"
end

if check("Resources seeded") { Resource.count >= 14 }
  checks_passed += 1
else
  checks_failed += 1
  errors << "Resources not seeded - run bin/rails rbac:seed"
end

if check("Actions seeded") { Action.count >= 10 }
  checks_passed += 1
else
  checks_failed += 1
  errors << "Actions not seeded - run bin/rails rbac:seed"
end

if check("Scopes seeded") { Scope.count >= 4 }
  checks_passed += 1
else
  checks_failed += 1
  errors << "Scopes not seeded - run bin/rails rbac:seed"
end

if check("Role permissions seeded") { RolePermission.count >= 400 }
  checks_passed += 1
else
  checks_failed += 1
  errors << "Role permissions not seeded - run bin/rails rbac:seed"
end

# ============================================================
# ROUTE CHECKS
# ============================================================
puts "\n=== API Routes ==="

routes = Rails.application.routes.routes.map(&:path).map(&:spec).map(&:to_s)

if check("Roles API routes exist") { 
  routes.any? { |r| r.include?('/api/v1/roles') } 
}
  checks_passed += 1
else
  checks_failed += 1
  errors << "Roles API routes missing - check config/routes.rb"
end

# ============================================================
# SUMMARY
# ============================================================
puts "\n╔════════════════════════════════════════════════════════╗"
puts "║                  VERIFICATION SUMMARY                 ║"
puts "╚════════════════════════════════════════════════════════╝"

puts "\nTotal Checks: #{checks_passed + checks_failed}"
puts "✅ Passed: #{checks_passed}"
puts "❌ Failed: #{checks_failed}"

if checks_failed > 0
  puts "\n⚠️  ERRORS FOUND:"
  errors.each { |error| puts "  - #{error}" }
  puts "\n❌ RBAC system is NOT ready"
  puts "\nFix the errors above and run verification again."
  exit 1
else
  puts "\n🎉 ALL CHECKS PASSED!"
  puts "\n✅ RBAC system is ready to use!"
  puts "\nNext Steps:"
  puts "  1. Run tests: bin/rails runner test/rbac_system_test.rb"
  puts "  2. Test migration: bin/rails rbac:migrate:test[1]"
  puts "  3. Enable RBAC: bin/rails rbac:migrate:company[1]"
  exit 0
end
