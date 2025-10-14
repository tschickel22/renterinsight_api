# Phase 4D Quick Reference Card

## 🚀 Quick Start (3 Commands)

```bash
# 1. Run all tests
./PHASE4D_ONE_COMMAND_TEST.sh

# 2. Create test data
ruby create_test_preferences.rb

# 3. Test API (use token from step 2)
curl -X GET http://localhost:3001/api/portal/preferences \
  -H 'Authorization: Bearer TOKEN_HERE' \
  -H 'Content-Type: application/json'
```

## 📡 API Endpoints

### GET /api/portal/preferences
**View current preferences**
```bash
curl -X GET http://localhost:3001/api/portal/preferences \
  -H 'Authorization: Bearer TOKEN' \
  -H 'Content-Type: application/json'
```
Returns: `{ok: true, preferences: {...}}`

### PATCH /api/portal/preferences  
**Update preferences**
```bash
curl -X PATCH http://localhost:3001/api/portal/preferences \
  -H 'Authorization: Bearer TOKEN' \
  -H 'Content-Type: application/json' \
  -d '{"preferences": {"email_opt_in": false}}'
```
Returns: `{ok: true, preferences: {...}}`

### GET /api/portal/preferences/history
**View change history (last 50)**
```bash
curl -X GET http://localhost:3001/api/portal/preferences/history \
  -H 'Authorization: Bearer TOKEN' \
  -H 'Content-Type: application/json'
```
Returns: `{ok: true, history: [...]}`

## 🎯 Preference Fields

| Field | Type | Description | Updatable via API |
|-------|------|-------------|-------------------|
| `email_opt_in` | boolean | Email communications | ✅ Yes |
| `sms_opt_in` | boolean | SMS/text communications | ✅ Yes |
| `marketing_opt_in` | boolean | Marketing materials | ✅ Yes |
| `portal_enabled` | boolean | Portal access (admin-controlled) | ❌ No (403) |

## ✅ Test Commands

```bash
# All tests
./PHASE4D_ONE_COMMAND_TEST.sh

# Controller only
bundle exec rspec spec/controllers/api/portal/preferences_controller_spec.rb

# Model only  
bundle exec rspec spec/models/buyer_portal_access_preferences_spec.rb

# Both with progress
bundle exec rspec spec/controllers/api/portal/preferences_controller_spec.rb \
  spec/models/buyer_portal_access_preferences_spec.rb --format progress
```

## 🔒 Security Rules

1. **JWT Required**: All endpoints need `Authorization: Bearer TOKEN`
2. **Cannot Disable Portal**: Attempting to set `portal_enabled: false` returns 403
3. **Boolean Only**: Non-boolean values return 422
4. **Valid Tokens**: Expired/invalid tokens return 401

## 📊 HTTP Status Codes

| Code | Meaning | When |
|------|---------|------|
| 200 | OK | Successful GET/PATCH |
| 401 | Unauthorized | Missing/invalid/expired token |
| 403 | Forbidden | Trying to modify `portal_enabled` |
| 404 | Not Found | Portal access doesn't exist |
| 422 | Unprocessable | Invalid boolean value |

## 🗂️ File Locations

```
app/
  models/buyer_portal_access.rb          # Model with tracking
  controllers/api/portal/
    preferences_controller.rb             # API controller

spec/
  models/buyer_portal_access_preferences_spec.rb    # Model tests (30+)
  controllers/api/portal/
    preferences_controller_spec.rb                   # Controller tests (30+)

config/routes.rb                          # Routes defined
create_test_preferences.rb                # Test data script

PHASE4D_COMPLETE_README.md                # Full documentation
PHASE4D_IMPLEMENTATION_SUMMARY.md         # Implementation details
PHASE4D_VERIFICATION_CHECKLIST.md         # Verification steps
```

## 💡 Common Tasks

### Create Test User with Token
```bash
ruby create_test_preferences.rb
```
Outputs: Email, password, JWT token, curl commands

### Get Current Preferences (Rails Console)
```ruby
portal = BuyerPortalAccess.find_by(email: 'buyer@test.com')
portal.preference_summary
# => {:email_opt_in=>true, :sms_opt_in=>false, ...}
```

### View Change History (Rails Console)
```ruby
portal = BuyerPortalAccess.last
portal.recent_preference_changes
# => [{timestamp: "...", changes: {...}}, ...]
```

### Manually Track a Change (Rails Console)
```ruby
portal = BuyerPortalAccess.last
portal.update!(email_opt_in: false)  # Automatically tracked!
portal.preference_history.last
# => {"timestamp"=>"...", "changes"=>{"email_opt_in"=>{"from"=>true, "to"=>false}}}
```

## 🎨 Example Responses

### GET Success (200)
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

### PATCH Success (200)
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

### History Success (200)
```json
{
  "ok": true,
  "history": [
    {
      "timestamp": "2025-10-14T16:30:00Z",
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

### Portal Disabled Error (403)
```json
{
  "ok": false,
  "error": "Cannot modify portal_enabled through API"
}
```

### Invalid Boolean Error (422)
```json
{
  "ok": false,
  "error": "Invalid preference values. Must be true or false."
}
```

### Auth Required Error (401)
```json
{
  "ok": false,
  "error": "Authentication required"
}
```

## 🏗️ Architecture Patterns

### Following Phase 4A/4B/4C
- ✅ Same JWT authentication pattern
- ✅ Same `{ok: true/false}` response format
- ✅ Same controller structure
- ✅ Same before_action flow
- ✅ Same test patterns

### SQLite Compatibility
- Uses `serialize :preference_history, coder: JSON`
- Works in dev (SQLite) and prod (PostgreSQL)
- No jsonb dependency

### Change Tracking
- Automatic via `before_update` callback
- Tracks only 4 preference fields
- ISO 8601 timestamps
- Immutable append (array + new entry)

## 📈 Test Coverage

- **Controller**: 30+ tests
  - Authentication: 4 scenarios × 3 endpoints = 12 tests
  - Show: 6 tests
  - Update: 18 tests (includes security)
  - History: 8 tests

- **Model**: 30+ tests
  - Serialization: 3 tests
  - Tracking: 12 tests
  - Validations: 4 tests
  - Scopes: 5 tests
  - Helpers: 6 tests

**Total: 60+ tests all passing** ✅

## 🔗 Related Phases

- **Phase 4A**: Authentication → Provides JWT tokens
- **Phase 4B**: Quotes → Uses email preferences for notifications
- **Phase 4C**: Documents → Uses email preferences for notifications
- **Phase 4D**: Preferences → You are here!

## ❓ Troubleshooting

### Tests Failing?
```bash
# Check database is migrated
rails db:migrate RAILS_ENV=test

# Reset test database
rails db:test:prepare

# Re-run tests
./PHASE4D_ONE_COMMAND_TEST.sh
```

### API Not Responding?
1. Check Rails server running: `rails s -p 3001`
2. Check database migrated: `rails db:migrate`
3. Verify JWT token not expired (24 hour limit)
4. Check Authorization header format: `Bearer TOKEN`

### History Not Tracking?
1. Verify field names match: `email_opt_in`, `sms_opt_in`, etc.
2. Use `update!` not direct assignment
3. Check `before_update` callback running
4. Verify `preference_history` field exists

---

## 📚 Full Documentation

- **Complete Guide**: `PHASE4D_COMPLETE_README.md`
- **Implementation Details**: `PHASE4D_IMPLEMENTATION_SUMMARY.md`
- **Verification Steps**: `PHASE4D_VERIFICATION_CHECKLIST.md`
- **This Quick Ref**: `PHASE4D_QUICK_REFERENCE.md`

---

**Phase 4D Status**: ✅ COMPLETE - All 60+ tests passing!
