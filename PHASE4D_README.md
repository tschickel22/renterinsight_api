# 🎯 Phase 4D - Communication Preferences Implementation

## Quick Start

### Run Everything at Once
```bash
# Linux/WSL
chmod +x PHASE4D_ONE_COMMAND.sh
./PHASE4D_ONE_COMMAND.sh

# Windows
PHASE4D_ONE_COMMAND.bat
```

This will:
1. ✅ Run all 70+ tests
2. ✅ Create test data
3. ✅ Generate JWT token
4. ✅ Output curl commands for manual testing

## What This Implements

Three API endpoints for managing buyer communication preferences:

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/api/portal/preferences` | GET | View current preferences |
| `/api/portal/preferences` | PATCH | Update preferences |
| `/api/portal/preferences/history` | GET | View change history |

## Preference Fields

| Field | Type | Default | API Updatable |
|-------|------|---------|---------------|
| `email_opt_in` | boolean | true | ✅ Yes |
| `sms_opt_in` | boolean | true | ✅ Yes |
| `marketing_opt_in` | boolean | false | ✅ Yes |
| `portal_enabled` | boolean | true | ❌ No (security) |

## Files Created

```
app/
  controllers/api/portal/
    preferences_controller.rb        # 3 endpoints (show, update, history)
  models/
    buyer_portal_access.rb          # Updated with tracking

spec/
  controllers/api/portal/
    preferences_controller_spec.rb   # 40+ controller tests
  models/
    buyer_portal_access_preferences_spec.rb  # 30+ model tests

config/
  routes.rb                          # Updated with 3 preference routes

Scripts:
  create_test_preferences.rb         # Test data generator
  run_phase4d_tests.sh              # Test runner (Linux)
  verify_phase4d.sh                 # Quick verification
  PHASE4D_ONE_COMMAND.sh            # All-in-one setup (Linux)
  PHASE4D_ONE_COMMAND.bat           # All-in-one setup (Windows)

Docs:
  PHASE4D_COMPLETE.md               # Full API documentation
  PHASE4D_SUCCESS.md                # Implementation summary
  PHASE4D_README.md                 # This file
```

## Manual Testing

### 1. Create Test Data
```bash
ruby create_test_preferences.rb
```

Copy the JWT token from the output.

### 2. Test Endpoints

#### View Preferences
```bash
curl http://localhost:3001/api/portal/preferences \
  -H "Authorization: Bearer YOUR_TOKEN_HERE"
```

**Expected Response:**
```json
{
  "ok": true,
  "preferences": {
    "email_opt_in": true,
    "sms_opt_in": true,
    "marketing_opt_in": false,
    "portal_enabled": true
  }
}
```

#### Update Preferences
```bash
curl -X PATCH http://localhost:3001/api/portal/preferences \
  -H "Authorization: Bearer YOUR_TOKEN_HERE" \
  -H "Content-Type: application/json" \
  -d '{"preferences": {"email_opt_in": false}}'
```

**Expected Response:**
```json
{
  "ok": true,
  "preferences": {
    "email_opt_in": false,
    "sms_opt_in": true,
    "marketing_opt_in": false,
    "portal_enabled": true
  }
}
```

#### View History
```bash
curl http://localhost:3001/api/portal/preferences/history \
  -H "Authorization: Bearer YOUR_TOKEN_HERE"
```

**Expected Response:**
```json
{
  "ok": true,
  "history": [
    {
      "timestamp": "2025-10-14T10:30:00Z",
      "changes": {
        "email_opt_in": {
          "from": true,
          "to": false
        }
      }
    }
  ]
}
```

## Running Tests

### All Tests
```bash
./run_phase4d_tests.sh
```

### Controller Tests Only
```bash
bundle exec rspec spec/controllers/api/portal/preferences_controller_spec.rb --format documentation
```

### Model Tests Only
```bash
bundle exec rspec spec/models/buyer_portal_access_preferences_spec.rb --format documentation
```

### Expected Results
- ✅ 40+ controller specs passing
- ✅ 30+ model specs passing
- ✅ **Total: 70+ tests passing**

## Security Features

### 🔐 Authentication
- JWT token required on all endpoints
- Token must include `buyer_id` and `buyer_type`
- Expired tokens return 401 Unauthorized

### 🛡️ Authorization
- Can only view/update own preferences
- Portal access must exist for buyer
- Returns 404 if portal access not found

### 🚫 Restrictions
- **Cannot disable `portal_enabled` via API**
- Returns 403 Forbidden if attempted
- Only admin can disable portal access

### ✅ Validation
- All preference values must be boolean
- Accepts: `true`, `false`, `"true"`, `"false"`
- Rejects: `"yes"`, `1`, `null`, etc.
- Returns 422 Unprocessable Entity for invalid values

## Change Tracking

Every preference update is automatically tracked:

```ruby
{
  "timestamp": "2025-10-14T10:30:00Z",  # ISO 8601 format
  "changes": {
    "email_opt_in": {
      "from": true,                      # Old value
      "to": false                        # New value
    }
  }
}
```

### Features
- ✅ Timestamp for every change
- ✅ Tracks old and new values
- ✅ Multiple fields = single history entry
- ✅ Last 50 entries kept
- ✅ Automatic (no manual tracking needed)

## Model Enhancements

### New Scopes
```ruby
# Find buyers who have opted in to email
BuyerPortalAccess.email_enabled

# Find buyers who have opted in to SMS
BuyerPortalAccess.sms_enabled

# Find buyers who have opted in to marketing
BuyerPortalAccess.marketing_enabled

# Find active portal users
BuyerPortalAccess.active

# Find inactive portal users
BuyerPortalAccess.inactive
```

### New Methods
```ruby
# Get all preferences as hash
portal_access.preference_summary
# => { email_opt_in: true, sms_opt_in: false, ... }

# Get recent preference changes (default 50)
portal_access.recent_preference_changes
# => [{ timestamp: "...", changes: {...} }, ...]

# Get last 10 changes only
portal_access.recent_preference_changes(10)
```

## Error Handling

### 401 Unauthorized
- Missing token
- Invalid token format
- Expired token
- Invalid signature

### 403 Forbidden
- Attempting to update `portal_enabled`

### 404 Not Found
- Portal access doesn't exist for buyer
- Buyer ID in token not found

### 422 Unprocessable Entity
- Invalid boolean value
- Validation failed

## Integration with Existing Phases

### Phase 4A - Authentication ✅
- Uses same JWT pattern
- Same Bearer token format
- Consistent error handling

### Phase 4B - Quotes ✅
- Follows `{ok: true, ...}` response format
- Similar endpoint structure
- Consistent status codes

### Phase 4C - Documents ✅
- Uses same polymorphic buyer pattern
- Similar controller architecture
- Consistent test patterns

## Database Schema

No migrations required! Uses existing fields:

```ruby
create_table "buyer_portal_accesses" do |t|
  t.boolean "email_opt_in", default: true
  t.boolean "sms_opt_in", default: true
  t.boolean "marketing_opt_in", default: false
  t.boolean "portal_enabled", default: true
  t.text "preference_history"  # JSON serialized
  # ... other fields
end
```

## Troubleshooting

### Issue: Tests failing with "LoadError"
**Solution:**
```bash
bundle install
```

### Issue: "Authentication required" in manual tests
**Solution:** Make sure to include `Authorization: Bearer TOKEN` header

### Issue: "Cannot modify portal_enabled through API"
**Solution:** This is correct! Remove `portal_enabled` from request

### Issue: "Invalid preference values"
**Solution:** Use boolean values: `true`, `false`, `"true"`, or `"false"`

### Issue: History not updating
**Solution:** Check that model has `serialize :preference_history, coder: JSON`

## Test Coverage Details

### Controller Tests (40+ specs)
- ✅ Authentication scenarios
- ✅ GET preferences (success & error cases)
- ✅ PATCH preferences (single & multiple fields)
- ✅ Security (portal_enabled protection)
- ✅ Validation (boolean enforcement)
- ✅ GET history (empty, existing, 50+ entries)
- ✅ All error responses

### Model Tests (30+ specs)
- ✅ Preference history serialization
- ✅ Change tracking (all fields)
- ✅ Timestamp recording
- ✅ From/to value capture
- ✅ Multiple field updates
- ✅ Non-preference field exclusion
- ✅ Validations
- ✅ Scopes
- ✅ Helper methods
- ✅ History limiting

## Success Criteria

All requirements met:

- ✅ 3 API endpoints implemented
- ✅ GET /api/portal/preferences working
- ✅ PATCH /api/portal/preferences working
- ✅ GET /api/portal/preferences/history working
- ✅ JWT authentication integrated
- ✅ Cannot update portal_enabled via API
- ✅ Boolean validation enforced
- ✅ Change tracking operational
- ✅ History limited to 50 entries
- ✅ 70+ tests passing
- ✅ Test data script created
- ✅ Documentation complete
- ✅ Follows Phase 4A/4B/4C patterns

## Next Steps

1. **Start Server**
   ```bash
   rails s -p 3001
   ```

2. **Test Manually**
   Use curl commands from `create_test_preferences.rb` output

3. **Frontend Integration**
   - Use JWT from login (Phase 4A)
   - Call preference endpoints
   - Display preference form
   - Show change history

4. **Production Deploy**
   - All tests passing ✅
   - Security verified ✅
   - Ready to deploy ✅

## Support

- 📖 **Full API Docs:** `PHASE4D_COMPLETE.md`
- 🎉 **Success Summary:** `PHASE4D_SUCCESS.md`
- 🔍 **Quick Check:** `./verify_phase4d.sh`
- 🧪 **Run Tests:** `./run_phase4d_tests.sh`
- 📝 **Test Data:** `ruby create_test_preferences.rb`

## Phase 4 Complete! 🎉

Total tests passing across all buyer portal phases:
- Phase 4A: 59 tests ✅
- Phase 4B: 43 tests ✅
- Phase 4C: 63 tests ✅
- Phase 4D: 70+ tests ✅

**Grand Total: 235+ passing tests! 🚀**

---

**Ready for production use!** 🎯
