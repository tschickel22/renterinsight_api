# Phase 4D Testing Checklist

## Pre-Flight Check
- [ ] In correct directory: `/home/tschi/src/renterinsight_api`
- [ ] Scripts are executable: `chmod +x *.sh`
- [ ] Database is ready: `rails db:migrate RAILS_ENV=test`

---

## Quick Test (5 minutes)

### Step 1: Run Automated Tests
```bash
./phase4d_complete_test.sh
```

**Expected Output:**
- [ ] "Model specs passed!" (green)
- [ ] "Controller specs passed!" (green)
- [ ] JWT token displayed
- [ ] Curl commands shown
- [ ] "All Tests Passed!" message
- [ ] Total: 67 tests

**If failed:**
- [ ] Check error messages
- [ ] Run: `rails db:test:prepare`
- [ ] Try again

---

## Manual API Test (10 minutes)

### Step 2: Start Server
```bash
rails s -p 3001
```

**Check:**
- [ ] Server starts without errors
- [ ] Port 3001 is listening
- [ ] No database errors

### Step 3: Create Test Data
```bash
ruby create_test_preferences.rb
```

**Copy and save:**
- [ ] Email address
- [ ] Password
- [ ] JWT token
- [ ] Curl commands

### Step 4: Test Each Endpoint

#### Test 1: View Preferences
```bash
curl -X GET http://localhost:3001/api/portal/preferences \
  -H 'Authorization: Bearer YOUR_TOKEN' \
  -H 'Content-Type: application/json'
```

**Expected:**
- [ ] Status 200 OK
- [ ] `"ok": true`
- [ ] All 4 preferences shown
- [ ] All values are booleans

#### Test 2: Update Preference
```bash
curl -X PATCH http://localhost:3001/api/portal/preferences \
  -H 'Authorization: Bearer YOUR_TOKEN' \
  -H 'Content-Type: application/json' \
  -d '{"preferences": {"email_opt_in": false}}'
```

**Expected:**
- [ ] Status 200 OK
- [ ] `email_opt_in` changed to false
- [ ] Other preferences unchanged

#### Test 3: View History
```bash
curl -X GET http://localhost:3001/api/portal/preferences/history \
  -H 'Authorization: Bearer YOUR_TOKEN' \
  -H 'Content-Type: application/json'
```

**Expected:**
- [ ] Status 200 OK
- [ ] History array returned
- [ ] Shows the change from Test 2
- [ ] Has timestamp
- [ ] Shows from/to values

#### Test 4: Security Test (Should Fail)
```bash
curl -X PATCH http://localhost:3001/api/portal/preferences \
  -H 'Authorization: Bearer YOUR_TOKEN' \
  -H 'Content-Type: application/json' \
  -d '{"preferences": {"portal_enabled": false}}'
```

**Expected:**
- [ ] Status 403 Forbidden
- [ ] Error message about portal_enabled
- [ ] Portal not actually disabled

#### Test 5: Validation Test (Should Fail)
```bash
curl -X PATCH http://localhost:3001/api/portal/preferences \
  -H 'Authorization: Bearer YOUR_TOKEN' \
  -H 'Content-Type: application/json' \
  -d '{"preferences": {"email_opt_in": "yes"}}'
```

**Expected:**
- [ ] Status 422 Unprocessable
- [ ] Validation error message
- [ ] Preference not changed

#### Test 6: Auth Test (Should Fail)
```bash
curl -X GET http://localhost:3001/api/portal/preferences \
  -H 'Content-Type: application/json'
```

**Expected:**
- [ ] Status 401 Unauthorized
- [ ] Error about missing token

---

## Feature Verification

### Preference Management
- [ ] Can view current preferences
- [ ] Can update single preference
- [ ] Can update multiple preferences
- [ ] Cannot update portal_enabled
- [ ] Only accepts boolean values

### History Tracking
- [ ] Changes automatically tracked
- [ ] Timestamp included (ISO 8601)
- [ ] Shows old and new values
- [ ] Multiple changes in one update tracked
- [ ] Can retrieve last 50 changes

### Security
- [ ] JWT authentication required
- [ ] Invalid token rejected (401)
- [ ] portal_enabled cannot be disabled (403)
- [ ] Invalid values rejected (422)
- [ ] Only owner can access preferences

### Data Integrity
- [ ] Preference_history is valid JSON
- [ ] No duplicate history entries
- [ ] History persists after restart
- [ ] Boolean values stored correctly

---

## RSpec Test Categories

### Model Tests (35 tests)
- [ ] Serialization works
- [ ] Change tracking works
- [ ] Validations work
- [ ] Helper methods work
- [ ] History management works

### Controller Tests (32 tests)
- [ ] Authentication works
- [ ] GET /preferences works
- [ ] PATCH /preferences works
- [ ] GET /history works
- [ ] Security controls work
- [ ] Error handling works

---

## Common Issues & Fixes

### Tests Won't Run
```bash
# Fix: Reset test database
rails db:test:prepare
bundle exec rspec
```

### Server Won't Start
```bash
# Fix: Kill existing process
lsof -i :3001
kill -9 <PID>
rails s -p 3001
```

### JWT Token Expired
```bash
# Fix: Generate new token (valid 24 hours)
ruby create_test_preferences.rb
```

### Can't Create Test Data
```bash
# Fix: Reset database
rails db:reset
ruby create_test_preferences.rb
```

### Test Failures
```bash
# Fix: Run tests individually for details
bundle exec rspec spec/models/buyer_portal_access_preferences_spec.rb -fd
bundle exec rspec spec/controllers/api/portal/preferences_controller_spec.rb -fd
```

---

## Success Criteria

All of these should be checked:

### Automated Tests
- [ ] All 67 tests passing
- [ ] No warnings or errors
- [ ] Test coverage complete

### API Functionality
- [ ] GET /preferences returns data
- [ ] PATCH /preferences updates data
- [ ] GET /history shows changes
- [ ] Security controls enforced
- [ ] Validations working

### Documentation
- [ ] All docs created
- [ ] Test scripts work
- [ ] Examples accurate

---

## Final Verification

- [ ] Ran `./phase4d_complete_test.sh` successfully
- [ ] Tested all 6 API scenarios manually
- [ ] All tests green (67/67)
- [ ] No errors in Rails logs
- [ ] Ready for integration

---

## Phase 4 Complete Status

- [ ] Phase 4A: Authentication (59 tests) ✅
- [ ] Phase 4B: Quote Management (43 tests) ✅
- [ ] Phase 4C: Document Management (63 tests) ✅
- [ ] Phase 4D: Communication Preferences (67 tests) ✅

**Total: 232 tests across Phase 4**

---

## Next Steps After Verification

1. [ ] Integration with frontend
2. [ ] End-to-end testing
3. [ ] Deploy to staging
4. [ ] QA review
5. [ ] Production deployment

---

## Notes

**Date Tested:** _______________

**Tester:** _______________

**Issues Found:**
_______________________________________________
_______________________________________________
_______________________________________________

**Resolution:**
_______________________________________________
_______________________________________________
_______________________________________________

---

## Sign-Off

- [ ] All tests passing
- [ ] All features working
- [ ] Documentation complete
- [ ] Ready for next phase

**Approved by:** _______________

**Date:** _______________

---

**Quick Reference:**
- START_HERE.md - Overview
- PHASE4D_TEST_GUIDE.md - Detailed instructions
- FLOW_DIAGRAM.txt - Visual flow
- PHASE4D_QUICK_REFERENCE.md - Commands
