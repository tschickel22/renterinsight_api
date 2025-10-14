# Phase 4D Verification Checklist

Use this checklist to verify Phase 4D is working correctly.

## ✅ Pre-Flight Checks

- [ ] Rails server running on port 3001
- [ ] Database migrated and seeded
- [ ] All Phase 4A/4B/4C tests passing

## 📋 Test Execution

### Automated Tests

- [ ] **Run controller tests**
  ```bash
  bundle exec rspec spec/controllers/api/portal/preferences_controller_spec.rb --format documentation
  ```
  Expected: 30+ tests passing

- [ ] **Run model tests**
  ```bash
  bundle exec rspec spec/models/buyer_portal_access_preferences_spec.rb --format documentation
  ```
  Expected: 30+ tests passing

- [ ] **Run one-command test**
  ```bash
  ./PHASE4D_ONE_COMMAND_TEST.sh  # Linux/WSL
  # OR
  PHASE4D_ONE_COMMAND_TEST.bat   # Windows
  ```
  Expected: All 60+ tests passing with green checkmarks

## 🧪 Manual API Testing

### Step 1: Create Test Data
```bash
ruby create_test_preferences.rb
```

- [ ] Script completes successfully
- [ ] Outputs JWT token
- [ ] Outputs curl commands
- [ ] Shows test lead email and password

### Step 2: Test GET /api/portal/preferences

Copy the first curl command from step 1 and run it.

- [ ] Returns HTTP 200
- [ ] Response has `"ok": true`
- [ ] Response has `preferences` object with 4 fields:
  - [ ] `email_opt_in`
  - [ ] `sms_opt_in`
  - [ ] `marketing_opt_in`
  - [ ] `portal_enabled`

Expected response:
```json
{
  "ok": true,
  "preferences": {
    "email_opt_in": true,
    "sms_opt_in": false,
    "marketing_opt_in": true,
    "portal_enabled": true
  }
}
```

### Step 3: Test PATCH /api/portal/preferences

Test updating a single preference:
```bash
curl -X PATCH http://localhost:3001/api/portal/preferences \
  -H 'Authorization: Bearer YOUR_TOKEN' \
  -H 'Content-Type: application/json' \
  -d '{"preferences": {"email_opt_in": false}}'
```

- [ ] Returns HTTP 200
- [ ] Response has `"ok": true`
- [ ] `email_opt_in` changed to `false`
- [ ] Other preferences unchanged

### Step 4: Test Multiple Preference Update

```bash
curl -X PATCH http://localhost:3001/api/portal/preferences \
  -H 'Authorization: Bearer YOUR_TOKEN' \
  -H 'Content-Type: application/json' \
  -d '{"preferences": {"email_opt_in": true, "sms_opt_in": true, "marketing_opt_in": false}}'
```

- [ ] Returns HTTP 200
- [ ] All three preferences updated correctly
- [ ] `portal_enabled` still `true` (unchanged)

### Step 5: Test GET /api/portal/preferences/history

```bash
curl -X GET http://localhost:3001/api/portal/preferences/history \
  -H 'Authorization: Bearer YOUR_TOKEN' \
  -H 'Content-Type: application/json'
```

- [ ] Returns HTTP 200
- [ ] Response has `"ok": true`
- [ ] Response has `history` array
- [ ] History array has entries (at least 2 from test data + your updates)
- [ ] Each entry has:
  - [ ] `timestamp` field
  - [ ] `changes` object
  - [ ] Each change shows `from` and `to` values

## 🔒 Security Testing

### Test 1: Try to Disable Portal
```bash
curl -X PATCH http://localhost:3001/api/portal/preferences \
  -H 'Authorization: Bearer YOUR_TOKEN' \
  -H 'Content-Type: application/json' \
  -d '{"preferences": {"portal_enabled": false}}'
```

- [ ] Returns HTTP 403 Forbidden
- [ ] Error message: "Cannot modify portal_enabled through API"
- [ ] `portal_enabled` remains `true` in database

### Test 2: Invalid Boolean Value
```bash
curl -X PATCH http://localhost:3001/api/portal/preferences \
  -H 'Authorization: Bearer YOUR_TOKEN' \
  -H 'Content-Type: application/json' \
  -d '{"preferences": {"email_opt_in": "yes"}}'
```

- [ ] Returns HTTP 422 Unprocessable Entity
- [ ] Error message about invalid boolean values
- [ ] Preferences not changed in database

### Test 3: Missing Authentication
```bash
curl -X GET http://localhost:3001/api/portal/preferences \
  -H 'Content-Type: application/json'
```

- [ ] Returns HTTP 401 Unauthorized
- [ ] Error message: "Authentication required"

### Test 4: Expired Token

Create an expired token (or wait 24 hours), then:

- [ ] Returns HTTP 401 Unauthorized  
- [ ] Error message: "Invalid or expired token"

## 📊 Database Verification

### Check BuyerPortalAccess Record

In Rails console (`rails c`):
```ruby
portal = BuyerPortalAccess.last
```

- [ ] `preference_history` is an Array
- [ ] Array contains Hash entries
- [ ] Each entry has `timestamp` and `changes` keys
- [ ] Timestamps are ISO 8601 format strings
- [ ] Changes show field names with `from`/`to` values

### Test Helper Methods

```ruby
portal = BuyerPortalAccess.last

# Test preference_summary
summary = portal.preference_summary
```
- [ ] Returns a Hash
- [ ] Has all 4 preference keys
- [ ] Values match database

```ruby
# Test recent_preference_changes
history = portal.recent_preference_changes
```
- [ ] Returns an Array
- [ ] Contains preference change entries
- [ ] Limited to 50 most recent

```ruby
# Test recent_preference_changes with limit
history = portal.recent_preference_changes(5)
```
- [ ] Returns last 5 changes only

## 🔍 Code Review Checklist

### Model (`app/models/buyer_portal_access.rb`)
- [ ] Has `serialize :preference_history, coder: JSON`
- [ ] Has `before_update :track_preference_changes`
- [ ] Validates all preference fields as boolean
- [ ] Has scopes for filtering
- [ ] Has `preference_summary` method
- [ ] Has `recent_preference_changes` method

### Controller (`app/controllers/api/portal/preferences_controller.rb`)
- [ ] Has `before_action :authenticate_portal_user!`
- [ ] Has `before_action :load_portal_access`
- [ ] `show` action returns preferences
- [ ] `update` action blocks `portal_enabled` changes
- [ ] `update` action validates boolean values
- [ ] `history` action limits to 50 entries
- [ ] All actions require authentication

### Routes (`config/routes.rb`)
- [ ] Has `get 'preferences'` route
- [ ] Has `patch 'preferences'` route
- [ ] Has `get 'preferences/history'` route
- [ ] All under `/api/portal` namespace

## 📈 Performance Checks

### History with Large Dataset

Create 100 preference changes:
```ruby
portal = BuyerPortalAccess.last
100.times { |i| portal.update!(email_opt_in: i.even?) }
```

Then test:
```bash
curl -X GET http://localhost:3001/api/portal/preferences/history \
  -H 'Authorization: Bearer YOUR_TOKEN' \
  -H 'Content-Type: application/json'
```

- [ ] Response returns in < 1 second
- [ ] Returns exactly 50 entries (last 50)
- [ ] Entries in chronological order

## ✅ Final Verification

All checks complete? Mark these:

- [ ] All automated tests passing (60+)
- [ ] All API endpoints working
- [ ] Security controls functioning
- [ ] History tracking working
- [ ] Database operations correct
- [ ] Performance acceptable
- [ ] Documentation complete

## 🎯 Success Criteria Met

Phase 4D is complete when:

✅ All automated tests pass (60+ tests)  
✅ All 3 API endpoints functional  
✅ Cannot disable portal through API  
✅ Boolean validation working  
✅ History limited to 50 entries  
✅ Authentication required  
✅ Change tracking automatic  
✅ Follows Phase 4A/4B/4C patterns  

---

**If all items are checked, Phase 4D is production-ready!** 🎉

## 📚 Next Steps

After verification:

1. Update Phase 4 master documentation
2. Deploy to staging environment
3. Frontend integration
4. End-to-end testing
5. Production deployment

---

**Questions or Issues?**

- Review `PHASE4D_COMPLETE_README.md` for detailed documentation
- Review `PHASE4D_IMPLEMENTATION_SUMMARY.md` for architecture details
- Check test output for specific failures
- Verify database schema matches expectations
