# RBAC Phase 1B - Quick Fix Instructions

## Issues Found
1. ✅ **FIXED**: Missing `company_id` column in `user_role_assignments` table
2. ✅ **FIXED**: User model `.active` scope issue in migration service

## Files Modified
1. `db/migrate/20251117000002_add_company_id_to_user_role_assignments.rb` - NEW migration
2. `app/services/rbac_migration_service.rb` - Fixed `.active` scope calls

---

## Commands to Run (in WSL Ubuntu terminal)

```bash
# Navigate to backend
cd ~/src/renterinsight_api

# Run the new migration
bin/rails db:migrate

# Verify migration success
bin/rails db:migrate:status | grep company_id

# Run RBAC status check
bin/rails rbac:status

# Run the test suite
bin/rails runner test/rbac_system_test.rb
```

---

## Expected Results

### After Migration:
```
== 20251117000002 AddCompanyIdToUserRoleAssignments: migrating ===============
-- add_column(:user_role_assignments, :company_id, :bigint)
-- add_index(:user_role_assignments, :company_id)
-- add_foreign_key(:user_role_assignments, :companies, {:on_delete=>:cascade})
-- change_column_null(:user_role_assignments, :company_id, false)
== 20251117000002 AddCompanyIdToUserRoleAssignments: migrated (0.0234s) ======
```

### After Test:
```
╔════════════════════════════════════════════════════════╗
║         RBAC SYSTEM TEST SUITE                        ║
╚════════════════════════════════════════════════════════╝

=== TEST 1: System Setup ===
Testing: System roles exist... ✅ PASS
Testing: Resources exist... ✅ PASS
Testing: Actions exist... ✅ PASS
Testing: Scopes exist... ✅ PASS

... (all tests should pass)

🎉 ALL TESTS PASSED!
```

---

## What Was Fixed

### 1. Missing company_id Column
**Problem**: The `user_role_assignments` table was missing the `company_id` column, causing queries to fail.

**Solution**: Created migration `20251117000002_add_company_id_to_user_role_assignments.rb` that:
- Adds `company_id` column
- Adds index for performance
- Adds foreign key constraint
- Backfills existing records from `users.company_id`
- Makes column NOT NULL after backfill

### 2. User Model .active Scope
**Problem**: `RbacMigrationService` was calling `company.users.active` but User model has no `.active` scope.

**Solution**: Changed all occurrences to use `.where(status: 'active')` instead:
- `company.users.where(status: 'active')` ✅
- `user.user_locations.where(active: true)` ✅

---

## If Migration Fails

If you get errors during migration, you can:

1. **Check current schema**:
   ```bash
   bin/rails db:schema:dump
   grep -A 10 "create_table \"user_role_assignments\"" db/schema.rb
   ```

2. **Manual rollback** (if needed):
   ```bash
   bin/rails db:rollback STEP=1
   ```

3. **Re-run migration**:
   ```bash
   bin/rails db:migrate
   ```

---

## Next Steps After Tests Pass

Once all tests pass:

1. **Test migration dry-run** for Company 1:
   ```bash
   bin/rails rbac:migrate:test[1]
   ```

2. **Review migration plan** - verify role mappings are correct

3. **Actually migrate** Company 1 (when ready):
   ```bash
   bin/rails rbac:migrate:company[1]
   ```

4. **Verify** migration succeeded:
   ```bash
   bin/rails rbac:status
   ```

---

## Troubleshooting

### Error: "column company_id already exists"
If the migration fails because column exists, you have two options:

**Option A: Skip if already added**
```bash
# Check if column exists
bin/rails runner "puts UserRoleAssignment.column_names.include?('company_id')"

# If true, mark migration as done
bin/rails db:migrate:up VERSION=20251117000002
```

**Option B: Modify migration** to check first:
```ruby
add_column :user_role_assignments, :company_id, :bigint unless column_exists?(:user_role_assignments, :company_id)
```

### Error: "RBAC system not seeded"
```bash
bin/rails rbac:seed
```

---

## Status Check

Run this command to see system status:
```bash
bin/rails rbac:status
```

Expected output:
- System Roles: 7
- Resources: 14
- Actions: 10
- Scopes: 4
- Companies: All showing RBAC disabled (ready for opt-in)

---

## Ready to Continue?

After running these commands and verifying tests pass, you can:

1. Say **"resume"** to continue to Phase 2 (Frontend)
2. Or say **"test migration for company 1"** to do a dry-run first
3. Or say **"show me the migration plan"** to review what will change
