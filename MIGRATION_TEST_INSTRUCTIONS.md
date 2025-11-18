# RBAC Migration Testing Instructions

## Prerequisites
Make sure Docker PostgreSQL is running and Rails environment is set up.

## Step-by-Step Testing

### 1. Navigate to Backend Directory
```bash
cd ~/src/renterinsight_api
```

### 2. Run the Migration
```bash
bin/rails db:migrate
```

Expected output:
```
== 20251117000001 CreateRbacSystem: migrating ================================
-- create_table(:resources)
   -> 0.0123s
-- create_table(:actions)
   -> 0.0089s
-- create_table(:scopes)
   -> 0.0091s
-- create_table(:roles)
   -> 0.0145s
-- create_table(:role_permissions)
   -> 0.0167s
-- create_table(:user_role_assignments)
   -> 0.0178s
-- add_column(:companies, :use_rbac_system, :boolean)
   -> 0.0034s
== 20251117000001 CreateRbacSystem: migrated (0.0827s) =======================
```

### 3. Run the Seed Data
```bash
bin/rails runner db/seeds/rbac_system_seed.rb
```

Expected output:
```
🔐 Seeding RBAC System...

📦 Seeding Resources...
✅ Created 14 resources

⚡ Seeding Actions...
✅ Created 10 actions

🎯 Seeding Scopes...
✅ Created 4 scopes

👥 Seeding Platform Default Roles...
✅ Created 7 system roles
✅ Created 350+ role permissions

================================================================================
RBAC System Seeding Complete!
================================================================================

📊 Summary:
   Resources: 14
   Actions: 10
   Scopes: 4
   System Roles: 7
   Role Permissions: 350+

🎉 Platform Default Roles:
   - Company Administrator (company): 140 permissions
   - Company Manager (company): XX permissions
   - Company Staff (company): XX permissions
   - Read-Only User (company): XX permissions
   - Location Administrator (location): XX permissions
   - Location Manager (location): XX permissions
   - Location Staff (location): XX permissions

✨ Ready to use! Companies can now:
   1. Enable RBAC with: company.update!(use_rbac_system: true)
   2. Create custom roles via UI
   3. Assign roles to users
================================================================================
```

### 4. Run Comprehensive Test
```bash
bin/rails runner test_rbac_migration.rb
```

Expected output:
```
🧪 Testing RBAC Migration - Phase 1A
============================================================

1️⃣ Checking database tables...
   ✅ resources: EXISTS
   ✅ actions: EXISTS
   ✅ scopes: EXISTS
   ✅ roles: EXISTS
   ✅ role_permissions: EXISTS
   ✅ user_role_assignments: EXISTS
   ✅ companies.use_rbac_system column: EXISTS

2️⃣ Checking seed data...
   ✅ Resources: 14
   ✅ Actions: 10
   ✅ Scopes: 4
   ✅ System Roles: 7
   ✅ Role Permissions: 350+

3️⃣ Platform Default Roles:
   - Company Administrator (company): 140 permissions
   - Company Manager (company): XX permissions
   - Company Staff (company): XX permissions
   - Read-Only User (company): XX permissions
   - Location Administrator (location): XX permissions
   - Location Manager (location): XX permissions
   - Location Staff (location): XX permissions

4️⃣ Testing Company Admin permissions...
   ✅ Company Admin role found
   - Total permissions: 140
   ✅ Can create inventory (all): true
   ✅ Can manage users (all): true
   ✅ Can read reports (all): true
   ✅ Can update branding (all): true

5️⃣ Testing Location Staff permissions...
   ✅ Location Staff role found
   - Total permissions: XX
   ✅ Can create inventory (assigned_locations): true
   ❌ Can delete inventory (assigned_locations): false (expected)
   ❌ Can manage users (all): false (expected)

6️⃣ Testing User model integration...
   ✅ User model loaded
   ✅ User#roles association: defined
   ✅ User#user_role_assignments association: defined
   ✅ User#uses_rbac? method: defined
   ✅ User#can? method: defined

7️⃣ Testing Company model integration...
   ✅ Company model loaded
   ✅ Company#roles association: defined
   ✅ Company#use_rbac_system field: false

============================================================
✅ Migration test complete!
============================================================
```

## Manual Verification Queries

You can also run these Rails console commands to verify:

```bash
bin/rails console
```

```ruby
# Check table counts
Resource.count          # Should be 14
Action.count            # Should be 10
Scope.count             # Should be 4
Role.system_roles.count # Should be 7
RolePermission.count    # Should be 350+

# List all resources
Resource.pluck(:key)
# => ["company_settings", "users", "locations", "inventory", "crm", "leads", 
#     "deals", "service", "finance", "reports", "portal", "branding", 
#     "communications", "listings"]

# List all actions
Action.pluck(:key)
# => ["create", "read", "update", "delete", "export", "import", 
#     "manage", "assign", "view_pii", "approve"]

# List all scopes
Scope.pluck(:key)
# => ["all", "assigned_regions", "assigned_locations", "own"]

# Check Company Admin permissions
company_admin = Role.find_by(key: 'company_admin')
company_admin.role_permissions.granted.count
# => 140 (14 resources × 10 actions)

# Test permission check
company_admin.has_permission?('inventory', 'create', 'all')
# => true

# Check if new column exists
Company.column_names.include?('use_rbac_system')
# => true

# Test User model integration
user = User.first
user.respond_to?(:roles)
# => true
user.respond_to?(:can?)
# => true
```

## If Migration Fails

If you encounter any errors:

1. **Check migration status:**
   ```bash
   bin/rails db:migrate:status
   ```

2. **Rollback if needed:**
   ```bash
   bin/rails db:rollback STEP=1
   ```

3. **Re-run migration:**
   ```bash
   bin/rails db:migrate
   ```

4. **Check PostgreSQL logs:**
   ```bash
   docker logs renterinsight_postgres
   ```

## Success Criteria

✅ All 6 tables created  
✅ companies.use_rbac_system column added  
✅ 14 resources seeded  
✅ 10 actions seeded  
✅ 4 scopes seeded  
✅ 7 system roles seeded  
✅ 350+ role permissions seeded  
✅ User model associations work  
✅ Company model associations work  
✅ Permission checks work  

---

**Once all tests pass, Phase 1A is complete and ready for Phase 1B!**
