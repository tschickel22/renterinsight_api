# ⚡ QUICK START - Phase 4D

## One Command to Test Everything

```bash
cd /home/tschi/src/renterinsight_api
chmod +x *.sh
./phase4d_complete_test.sh
```

**That's it!** This will:
- ✅ Run 67 tests (30 seconds)
- ✅ Create test user + JWT token
- ✅ Show you curl commands
- ✅ Display complete summary

---

## Expected Output

```
🚀 Phase 4D: Communication Preferences
   Complete Test Suite

Step 1: Running RSpec Tests
✅ Model specs passed!
✅ Controller specs passed!

Step 2: Creating Test Data
✅ Test data created!
   JWT Token: [your token here]
   Curl commands: [ready to use]

Step 3: Test Summary
✅ All Tests Passed!
   • Total: 67 tests
   • Features: All working
   
🎉 Phase 4D Implementation Complete!
```

---

## If Tests Pass ✅

**You're done!** Phase 4D is working perfectly.

**Next steps:**
1. Use the JWT token and curl commands to test manually (optional)
2. Integrate with frontend
3. Deploy to staging

---

## If Tests Fail ❌

### Quick Fixes

**Database issue?**
```bash
rails db:test:prepare
./phase4d_complete_test.sh
```

**Still failing?**
```bash
# Run with details
bundle exec rspec spec/models/buyer_portal_access_preferences_spec.rb -fd
bundle exec rspec spec/controllers/api/portal/preferences_controller_spec.rb -fd
```

**Need help?**
- Check error messages in test output
- Read [PHASE4D_TEST_GUIDE.md](PHASE4D_TEST_GUIDE.md)
- Review [INDEX.md](INDEX.md) for all docs

---

## Files to Know About

### Test Scripts (Run These)
- `phase4d_complete_test.sh` ⭐ **Run this one!**
- `test_phase4d.sh` - Quick 10-second test
- `phase4d_manual_test.sh` - Interactive testing

### Documentation (Read These)
- `START_HERE.md` ⭐ **Complete guide**
- `INDEX.md` - List of all files
- `PHASE4D_TEST_GUIDE.md` - Detailed testing

---

## Manual Testing (Optional)

### Start Server
```bash
rails s -p 3001
```

### Get Test Data
```bash
ruby create_test_preferences.rb
```

Copy the JWT token, then test:

```bash
# View preferences
curl -X GET http://localhost:3001/api/portal/preferences \
  -H 'Authorization: Bearer YOUR_TOKEN'

# Update preference
curl -X PATCH http://localhost:3001/api/portal/preferences \
  -H 'Authorization: Bearer YOUR_TOKEN' \
  -d '{"preferences": {"email_opt_in": false}}'

# View history
curl -X GET http://localhost:3001/api/portal/preferences/history \
  -H 'Authorization: Bearer YOUR_TOKEN'
```

---

## What Phase 4D Does

**3 API Endpoints:**
1. GET /api/portal/preferences - View current
2. PATCH /api/portal/preferences - Update  
3. GET /api/portal/preferences/history - View changes

**Security:**
- JWT authentication required
- Cannot disable portal_enabled
- Boolean validation only

**Tracking:**
- All changes automatically logged
- Shows old → new values
- Last 50 changes available

---

## Phase 4 Complete!

| Phase | Tests | Status |
|-------|-------|--------|
| 4A | 59 | ✅ |
| 4B | 43 | ✅ |
| 4C | 63 | ✅ |
| 4D | 67 | ✅ |

**Total: 232 tests!** 🎉

---

## TL;DR

```bash
# Just run this:
./phase4d_complete_test.sh

# See this:
✅ All Tests Passed!

# You're done! ✅
```

---

**More details?** Read [START_HERE.md](START_HERE.md)

**All documentation?** See [INDEX.md](INDEX.md)

**Ready to test?** Run the command above! ⚡
