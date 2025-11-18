#!/bin/bash
# Quick Test Script - Run all RBAC migration tests
# Usage: cd ~/src/renterinsight_api && bash quick_test.sh

set -e  # Exit on error

echo "🧪 RBAC Migration Quick Test"
echo "=============================="
echo ""

# 1. Run migration
echo "1️⃣ Running migration..."
bin/rails db:migrate
echo ""

# 2. Run seed
echo "2️⃣ Seeding data..."
bin/rails runner db/seeds/rbac_system_seed.rb
echo ""

# 3. Quick verification
echo "3️⃣ Quick verification..."
bin/rails runner "
puts 'Tables: ' + %w[resources actions scopes roles role_permissions user_role_assignments].all? { |t| ActiveRecord::Base.connection.table_exists?(t) }.to_s
puts 'Resources: ' + Resource.count.to_s
puts 'Actions: ' + Action.count.to_s
puts 'Scopes: ' + Scope.count.to_s
puts 'Roles: ' + Role.system_roles.count.to_s
puts 'Permissions: ' + RolePermission.count.to_s
puts ''
puts '✅ Migration successful!' if Resource.count == 14 && Action.count == 10
"
echo ""

# 4. Run full test
echo "4️⃣ Running comprehensive test..."
bin/rails runner test_rbac_migration.rb

echo ""
echo "✅ All tests complete!"
