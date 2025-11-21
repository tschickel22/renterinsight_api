# Fix RBAC Permissions
# Run this script in Rails console: rails c
# Then: load 'lib/scripts/fix_rbac_permissions.rb'

puts "=" * 80
puts "RBAC Permission Diagnostic and Fix Script"
puts "=" * 80

# Find the test user
user = User.find_by(email: 't+hil89@renterinsight.com')
unless user
  puts "❌ User not found!"
  exit
end

puts "\n✅ Found user: #{user.email} (ID: #{user.id})"
puts "   Company: #{user.company.name} (ID: #{user.company_id})"
puts "   Uses RBAC: #{user.uses_rbac?}"

# Check user's roles
puts "\n📋 User's Roles:"
user.roles.each do |role|
  puts "   - #{role.name} (#{role.key}) [Tier: #{role.tier}, Active: #{role.active}]"
end

if user.roles.empty?
  puts "   ❌ No roles assigned!"
end

# Seed resources if needed
puts "\n🌱 Checking Resources..."
Resource.seed_defaults
resources_count = Resource.count
puts "   ✅ #{resources_count} resources available"

# Check for 'leads' resource
leads_resource = Resource.find_by(key: 'leads')
if leads_resource
  puts "   ✅ 'leads' resource exists (ID: #{leads_resource.id})"
else
  puts "   ❌ 'leads' resource not found!"
end

# Seed actions if needed
puts "\n🌱 Checking Actions..."
Action.seed_defaults if Action.respond_to?(:seed_defaults)
actions_count = Action.count
puts "   ✅ #{actions_count} actions available"

# Check for 'read' action
read_action = Action.find_by(key: 'read')
if read_action
  puts "   ✅ 'read' action exists (ID: #{read_action.id})"
else
  puts "   ❌ 'read' action not found!"
end

# Seed scopes if needed
puts "\n🌱 Checking Scopes..."
Scope.seed_defaults if Scope.respond_to?(:seed_defaults)
scopes_count = Scope.count
puts "   ✅ #{scopes_count} scopes available"

# Check for 'all' scope
all_scope = Scope.find_by(key: 'all')
if all_scope
  puts "   ✅ 'all' scope exists (ID: #{all_scope.id})"
else
  puts "   ❌ 'all' scope not found!"
end

# Check if company_admin role exists
puts "\n👤 Checking company_admin role..."
company_admin_role = Role.find_by(key: 'company_admin', tier: 'company')
if company_admin_role
  puts "   ✅ company_admin role exists (ID: #{company_admin_role.id})"
  
  # Check if role has any permissions
  permissions_count = company_admin_role.role_permissions.where(granted: true).count
  puts "   📊 Role has #{permissions_count} granted permissions"
  
  if permissions_count == 0
    puts "   ⚠️  No permissions granted to company_admin role!"
    puts "   🔧 Granting full permissions to company_admin..."
    
    # Grant full permissions
    all_scope = Scope.find_by!(key: 'all')
    Resource.active.each do |resource|
      Action.all.each do |action|
        RolePermission.find_or_create_by!(
          role: company_admin_role,
          resource: resource,
          action: action,
          scope: all_scope
        ) do |permission|
          permission.granted = true
        end
      end
    end
    
    new_count = company_admin_role.role_permissions.where(granted: true).count
    puts "   ✅ Granted #{new_count} permissions to company_admin role"
  end
  
  # Check specific permission for leads:read:all
  if leads_resource && read_action && all_scope
    has_leads_read = company_admin_role.role_permissions.exists?(
      resource: leads_resource,
      action: read_action,
      scope: all_scope,
      granted: true
    )
    
    if has_leads_read
      puts "   ✅ company_admin has leads:read:all permission"
    else
      puts "   ❌ company_admin MISSING leads:read:all permission"
      puts "   🔧 Granting leads:read:all permission..."
      
      RolePermission.find_or_create_by!(
        role: company_admin_role,
        resource: leads_resource,
        action: read_action,
        scope: all_scope
      ) do |permission|
        permission.granted = true
      end
      
      puts "   ✅ Permission granted!"
    end
  end
else
  puts "   ❌ company_admin role not found!"
  puts "   🔧 Creating company_admin role..."
  Role.seed_defaults
  company_admin_role = Role.find_by(key: 'company_admin', tier: 'company')
  puts "   ✅ company_admin role created!"
end

# Check user's role assignment
puts "\n🔗 Checking User Role Assignment..."
assignment = UserRoleAssignment.find_by(user: user, role: company_admin_role)
if assignment
  puts "   ✅ User has company_admin role assigned"
  puts "      Tier: #{assignment.tier}"
  puts "      Location ID: #{assignment.location_id || 'N/A'}"
  puts "      Region ID: #{assignment.region_id || 'N/A'}"
else
  puts "   ❌ User NOT assigned to company_admin role!"
  puts "   🔧 Assigning company_admin role to user..."
  
  UserRoleAssignment.create!(
    user: user,
    role: company_admin_role,
    tier: 'company',
    location_id: nil,
    region_id: nil
  )
  
  puts "   ✅ Role assigned!"
end

# Clear permission cache
puts "\n🧹 Clearing permission cache for user..."
Rails.cache.delete_matched("permissions:#{user.id}:*")
puts "   ✅ Cache cleared"

# Test the permission
puts "\n🧪 Testing permission check..."
puts "   Testing: user.can?('leads', 'read', 'all')"
result = user.can?('leads', 'read', 'all')
if result
  puts "   ✅ Permission check PASSED!"
else
  puts "   ❌ Permission check FAILED!"
  
  # Detailed debugging
  puts "\n🔍 Detailed Debug:"
  puts "   User uses_rbac?: #{user.uses_rbac?}"
  puts "   User roles count: #{user.roles.active.count}"
  user.roles.active.each do |role|
    has_perm = role.has_permission?('leads', 'read', 'all')
    puts "   Role '#{role.name}' has leads:read:all: #{has_perm}"
  end
end

puts "\n" + "=" * 80
puts "Diagnostic complete!"
puts "=" * 80
