# frozen_string_literal: true

# RBAC System Test Script
#
# Run with: bin/rails runner test/rbac_system_test.rb
#
# Tests:
# 1. PermissionService functionality
# 2. User role assignments
# 3. Permission checking with scopes
# 4. Cache invalidation
# 5. Migration service
# 6. Authorization helpers

puts "\n╔════════════════════════════════════════════════════════╗"
puts "║         RBAC SYSTEM TEST SUITE                        ║"
puts "╚════════════════════════════════════════════════════════╝\n"

# Test counters
tests_passed = 0
tests_failed = 0
test_errors = []

def test(description)
  print "Testing: #{description}... "
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
# TEST 1: System Setup
# ============================================================
puts "\n=== TEST 1: System Setup ==="

if test("System roles exist") { Role.system_roles.count >= 7 }
  tests_passed += 1
else
  tests_failed += 1
  test_errors << "System roles not found - run bin/rails rbac:seed"
end

if test("Resources exist") { Resource.count >= 14 }
  tests_passed += 1
else
  tests_failed += 1
  test_errors << "Resources not found - run bin/rails rbac:seed"
end

if test("Actions exist") { Action.count >= 10 }
  tests_passed += 1
else
  tests_failed += 1
  test_errors << "Actions not found - run bin/rails rbac:seed"
end

if test("Scopes exist") { Scope.count >= 4 }
  tests_passed += 1
else
  tests_failed += 1
  test_errors << "Scopes not found - run bin/rails rbac:seed"
end

# ============================================================
# TEST 2: Test Company Setup
# ============================================================
puts "\n=== TEST 2: Test Company Setup ==="

# Get or create test company
test_company = Company.first || Company.create!(
  name: "RBAC Test Company",
  subdomain: "rbactest",
  active: true,
  use_rbac_system: false
)

# Disable RBAC if it's already enabled (for clean testing)
if test_company.use_rbac_system
  test_company.update!(use_rbac_system: false)
end

if test("Test company exists") { test_company.present? }
  tests_passed += 1
else
  tests_failed += 1
  test_errors << "Failed to create test company"
end

if test("Test company RBAC initially disabled") { !test_company.reload.use_rbac_system }
  tests_passed += 1
else
  tests_failed += 1
  test_errors << "Test company should start with RBAC disabled"
end

# ============================================================
# TEST 3: Enable RBAC for Company
# ============================================================
puts "\n=== TEST 3: Enable RBAC ==="

test_company.update!(use_rbac_system: true)

if test("RBAC enabled for company") { test_company.reload.use_rbac_system }
  tests_passed += 1
else
  tests_failed += 1
  test_errors << "Failed to enable RBAC"
end

# ============================================================
# TEST 4: User Role Assignments
# ============================================================
puts "\n=== TEST 4: User Role Assignments ==="

# Create test user
test_user = test_company.users.first || test_company.users.create!(
  email: "rbac_test@example.com",
  password: "test123456",
  first_name: "RBAC",
  last_name: "Test",
  role: "admin",
  status: "active"
)

# Assign company admin role
company_admin_role = Role.find_by!(key: 'company_admin', tier: 'company', is_system_role: true)
user_assignment = test_user.user_role_assignments.find_or_create_by!(
  role: company_admin_role,
  tier: 'company',
  company_id: test_company.id
)

if test("User role assignment created") { user_assignment.persisted? }
  tests_passed += 1
else
  tests_failed += 1
  test_errors << "Failed to create user role assignment"
end

if test("User has company admin role") { test_user.reload.has_role?('company_admin') }
  tests_passed += 1
else
  tests_failed += 1
  test_errors << "User doesn't have company_admin role"
end

if test("User.uses_rbac? returns true") { test_user.uses_rbac? }
  tests_passed += 1
else
  tests_failed += 1
  test_errors << "User.uses_rbac? should return true"
end

# ============================================================
# TEST 5: PermissionService - Basic Checks
# ============================================================
puts "\n=== TEST 5: PermissionService - Basic Permissions ==="

service = PermissionService.new(test_user)

if test("PermissionService initializes") { service.present? }
  tests_passed += 1
else
  tests_failed += 1
  test_errors << "PermissionService failed to initialize"
end

if test("Admin can create inventory (all scope)") { service.can?('inventory', 'create', 'all') }
  tests_passed += 1
else
  tests_failed += 1
  test_errors << "Company admin should have inventory:create:all"
end

if test("Admin can read users") { service.can?('users', 'read', 'all') }
  tests_passed += 1
else
  tests_failed += 1
  test_errors << "Company admin should have users:read:all"
end

if test("Admin can manage settings") { service.can?('company_settings', 'manage', 'all') }
  tests_passed += 1
else
  tests_failed += 1
  test_errors << "Company admin should have company_settings:manage:all"
end

# ============================================================
# TEST 6: PermissionService - Scope Validation
# ============================================================
puts "\n=== TEST 6: PermissionService - Scope Validation ==="

# Create test location
test_location = test_company.locations.first || test_company.locations.create!(
  name: "Test Location",
  address_line1: "123 Test St",
  active: true,
  is_deleted: false
)

if test("Test location created") { test_location.persisted? }
  tests_passed += 1
else
  tests_failed += 1
  test_errors << "Failed to create test location"
end

# Company admin should access all locations
if test("Admin can access test location") { service.can_access_location?(test_location.id) }
  tests_passed += 1
else
  tests_failed += 1
  test_errors << "Company admin should access all locations"
end

# Create limited user with location scope
limited_user = test_company.users.create!(
  email: "limited_user@example.com",
  password: "test123456",
  first_name: "Limited",
  last_name: "User",
  role: "staff",
  status: "active"
)

location_staff_role = Role.find_by!(key: 'location_staff', tier: 'location', is_system_role: true)
limited_user.user_role_assignments.create!(
  role: location_staff_role,
  tier: 'location',
  company_id: test_company.id,
  location_id: test_location.id
)

limited_service = PermissionService.new(limited_user)

if test("Limited user can access assigned location") { 
  limited_service.can_access_location?(test_location.id) 
}
  tests_passed += 1
else
  tests_failed += 1
  test_errors << "Location staff should access assigned location"
end

# Create another location
other_location = test_company.locations.create!(
  name: "Other Location",
  address_line1: "456 Other St",
  active: true,
  is_deleted: false
)

if test("Limited user CANNOT access unassigned location") { 
  !limited_service.can_access_location?(other_location.id) 
}
  tests_passed += 1
else
  tests_failed += 1
  test_errors << "Location staff should NOT access unassigned locations"
end

# ============================================================
# TEST 7: Permission Caching
# ============================================================
puts "\n=== TEST 7: Permission Caching ==="

# Clear cache first
service.clear_cache

# First call should cache
result1 = service.can?('inventory', 'create', 'all')
cache_key = "permissions:#{test_user.id}:inventory:create:all"

if test("Permission cached after first check") { Rails.cache.exist?(cache_key) }
  tests_passed += 1
else
  tests_failed += 1
  test_errors << "Permission should be cached"
end

# Clear cache
service.clear_cache

if test("Cache cleared successfully") { !Rails.cache.exist?(cache_key) }
  tests_passed += 1
else
  tests_failed += 1
  test_errors << "Cache should be cleared"
end

# ============================================================
# TEST 8: User Helper Methods
# ============================================================
puts "\n=== TEST 8: User Helper Methods ==="

if test("User.can? method works") { test_user.can?('inventory', 'create') }
  tests_passed += 1
else
  tests_failed += 1
  test_errors << "User.can? helper method failed"
end

if test("User.company_admin? returns true") { test_user.company_admin? }
  tests_passed += 1
else
  tests_failed += 1
  test_errors << "User.company_admin? should return true"
end

accessible_locations = test_user.accessible_locations
if test("User.accessible_locations returns locations") { accessible_locations.count > 0 }
  tests_passed += 1
else
  tests_failed += 1
  test_errors << "User.accessible_locations should return locations"
end

# ============================================================
# TEST 9: Migration Service (Dry Run)
# ============================================================
puts "\n=== TEST 9: Migration Service ==="

# Create a second test company for migration
migration_company = Company.create!(
  name: "Migration Test Company",
  subdomain: "migrationtest",
  active: true,
  use_rbac_system: false
)

# Create legacy user
legacy_user = migration_company.users.create!(
  email: "legacy@example.com",
  password: "test123456",
  first_name: "Legacy",
  last_name: "User",
  role: "admin",
  status: "active"
)

migration_service = RbacMigrationService.new(migration_company)

if test("Migration service initializes") { migration_service.present? }
  tests_passed += 1
else
  tests_failed += 1
  test_errors << "Migration service failed to initialize"
end

# Test dry run
migration_plan = migration_service.test_migration

if test("Migration plan generated") { migration_plan[:users].count > 0 }
  tests_passed += 1
else
  tests_failed += 1
  test_errors << "Migration plan should include users"
end

if test("Migration plan includes legacy user") {
  migration_plan[:users].any? { |u| u[:email] == legacy_user.email }
}
  tests_passed += 1
else
  tests_failed += 1
  test_errors << "Migration plan should include legacy user"
end

# ============================================================
# TEST SUMMARY
# ============================================================
puts "\n╔════════════════════════════════════════════════════════╗"
puts "║                  TEST SUMMARY                         ║"
puts "╚════════════════════════════════════════════════════════╝"
puts "\nTotal Tests: #{tests_passed + tests_failed}"
puts "✅ Passed: #{tests_passed}"
puts "❌ Failed: #{tests_failed}"

if tests_failed > 0
  puts "\n⚠️  ERRORS:"
  test_errors.each { |error| puts "  - #{error}" }
  puts "\n"
  exit 1
else
  puts "\n🎉 ALL TESTS PASSED!"
  puts "\nNext Steps:"
  puts "  1. Test API endpoints: bin/rails routes | grep roles"
  puts "  2. Test in Rails console: bin/rails console"
  puts "  3. Migrate your company: bin/rails rbac:migrate:test[1]"
  puts "  4. Enable RBAC: bin/rails rbac:migrate:company[1]"
  puts "\n"
  exit 0
end
