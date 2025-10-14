# Phase 4D: Communication Preferences - COMPLETE ✅

## Overview
Phase 4D implements communication preference management for the buyer portal, allowing buyers to control their email, SMS, and marketing preferences with full change history tracking.

## Implementation Status: 100% Complete

### ✅ Completed Components

#### 1. Model Updates (`app/models/buyer_portal_access.rb`)
- ✅ JSON serialization for `preference_history` (SQLite compatible)
- ✅ Automatic change tracking via `before_update` callback
- ✅ Validates all preference fields as boolean
- ✅ Scopes for filtering by preferences
- ✅ Helper methods: `preference_summary`, `recent_preference_changes`

#### 2. Controller (`app/controllers/api/portal/preferences_controller.rb`)
- ✅ `GET /api/portal/preferences` - View current preferences
- ✅ `PATCH /api/portal/preferences` - Update preferences
- ✅ `GET /api/portal/preferences/history` - View change history
- ✅ JWT authentication required for all endpoints
- ✅ Security: Cannot modify `portal_enabled` via API
- ✅ Validation: Only accepts boolean values

#### 3. Routes (`config/routes.rb`)
- ✅ All preference routes under `/api/portal/` namespace
- ✅ RESTful design following Phase 4A/4B/4C patterns

#### 4. Tests
- ✅ Controller specs: 30+ test cases
- ✅ Model specs: 30+ test cases
- ✅ Total: 60+ tests covering all scenarios

#### 5. Test Data Script (`create_test_preferences.rb`)
- ✅ Creates test lead and portal access
- ✅ Generates JWT token for testing
- ✅ Provides curl commands for all endpoints
- ✅ Creates sample preference history

## API Endpoints

### 1. GET /api/portal/preferences
View current communication preferences.

**Authentication**: JWT Bearer token required

**Response**:
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

### 2. PATCH /api/portal/preferences
Update communication preferences.

**Authentication**: JWT Bearer token required

**Request Body**:
```json
{
  "preferences": {
    "email_opt_in": false,
    "sms_opt_in": true,
    "marketing_opt_in": false
  }
}
```

**Response**:
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

**Security**:
- ❌ Cannot update `portal_enabled` (returns 403 Forbidden)
- ✅ Only boolean values accepted (true/false or "true"/"false")
- ❌ Invalid values return 422 Unprocessable Entity

### 3. GET /api/portal/preferences/history
View preference change history (last 50 changes).

**Authentication**: JWT Bearer token required

**Response**:
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
    },
    {
      "timestamp": "2025-10-14T16:35:00Z",
      "changes": {
        "sms_opt_in": {
          "from": false,
          "to": true
        },
        "marketing_opt_in": {
          "from": true,
          "to": false
        }
      }
    }
  ]
}
```

## Business Rules

### Preference Fields
1. **email_opt_in**: Controls email communications
2. **sms_opt_in**: Controls SMS/text communications  
3. **marketing_opt_in**: Controls marketing materials
4. **portal_enabled**: Admin-controlled portal access (cannot be changed via API)

### Change Tracking
- All preference changes automatically tracked in `preference_history`
- Each entry includes:
  - ISO 8601 timestamp
  - Changed fields with from/to values
- History limited to last 50 entries
- Multiple field changes in single update recorded as one entry

### Security
- All endpoints require JWT authentication
- Cannot disable portal access through API
- Only valid boolean values accepted
- Returns appropriate HTTP status codes

## Running Tests

### Run All Phase 4D Tests
```bash
./run_phase4d_complete_tests.sh
```

Or individually:

```bash
# Controller tests
bundle exec rspec spec/controllers/api/portal/preferences_controller_spec.rb --format documentation

# Model tests
bundle exec rspec spec/models/buyer_portal_access_preferences_spec.rb --format documentation
```

### Test Coverage
- **Controller**: 30+ tests
  - Authentication scenarios (valid, expired, invalid, missing)
  - Show endpoint (6 tests)
  - Update endpoint (18 tests)
  - History endpoint (8 tests)
  
- **Model**: 30+ tests
  - Serialization (3 tests)
  - Change tracking (12 tests)
  - Validations (4 tests)
  - Scopes (5 tests)
  - Helper methods (6 tests)

## Testing with curl

### 1. Create Test Data
```bash
ruby create_test_preferences.rb
```

This will output:
- Test lead credentials
- JWT token (valid 24 hours)
- Sample curl commands

### 2. Test Endpoints

**Get Preferences**:
```bash
curl -X GET http://localhost:3001/api/portal/preferences \
  -H 'Authorization: Bearer YOUR_TOKEN_HERE' \
  -H 'Content-Type: application/json'
```

**Update Single Preference**:
```bash
curl -X PATCH http://localhost:3001/api/portal/preferences \
  -H 'Authorization: Bearer YOUR_TOKEN_HERE' \
  -H 'Content-Type: application/json' \
  -d '{"preferences": {"email_opt_in": false}}'
```

**Update Multiple Preferences**:
```bash
curl -X PATCH http://localhost:3001/api/portal/preferences \
  -H 'Authorization: Bearer YOUR_TOKEN_HERE' \
  -H 'Content-Type: application/json' \
  -d '{"preferences": {"email_opt_in": true, "sms_opt_in": false, "marketing_opt_in": true}}'
```

**Get History**:
```bash
curl -X GET http://localhost:3001/api/portal/preferences/history \
  -H 'Authorization: Bearer YOUR_TOKEN_HERE' \
  -H 'Content-Type: application/json'
```

**Try to Disable Portal (should fail with 403)**:
```bash
curl -X PATCH http://localhost:3001/api/portal/preferences \
  -H 'Authorization: Bearer YOUR_TOKEN_HERE' \
  -H 'Content-Type: application/json' \
  -d '{"preferences": {"portal_enabled": false}}'
```

**Invalid Boolean (should fail with 422)**:
```bash
curl -X PATCH http://localhost:3001/api/portal/preferences \
  -H 'Authorization: Bearer YOUR_TOKEN_HERE' \
  -H 'Content-Type: application/json' \
  -d '{"preferences": {"email_opt_in": "yes"}}'
```

## Database Schema

### Existing Fields in `buyer_portal_accesses`
```ruby
t.boolean :email_opt_in, default: true
t.boolean :sms_opt_in, default: true
t.boolean :marketing_opt_in, default: false
t.boolean :portal_enabled, default: true
t.text :preference_history  # Serialized JSON
```

No migrations needed - uses existing fields!

## Architecture Decisions

### 1. SQLite Compatibility
- Used `serialize :preference_history, coder: JSON` instead of jsonb
- Works with both SQLite (development) and PostgreSQL (production)

### 2. Change Tracking
- Implemented in `before_update` callback
- Only tracks the 4 preference fields
- Appends to array (not mutating for Rails tracking)
- ISO 8601 timestamps for consistency

### 3. Security
- Portal enabled flag protected (cannot be disabled by buyer)
- Strict boolean validation
- JWT authentication on all endpoints
- Proper HTTP status codes

### 4. Following Established Patterns
- Matches Phase 4A/4B/4C controller structure
- Same authentication pattern
- Consistent JSON response format: `{ok: true/false, ...}`
- Same error handling approach

## Integration with Other Phases

### Phase 4A (Authentication)
- Uses same JWT token structure
- Same authentication helper pattern
- Consistent error responses

### Phase 4B (Quotes)
- Email preferences affect quote notifications
- Marketing preferences affect quote follow-ups

### Phase 4C (Documents)
- Email preferences affect document notifications
- Portal enabled controls document access

## Files Modified/Created

### Modified
- ✅ `app/models/buyer_portal_access.rb` - Added serialization and tracking
- ✅ `config/routes.rb` - Added preference routes

### Created
- ✅ `app/controllers/api/portal/preferences_controller.rb`
- ✅ `spec/controllers/api/portal/preferences_controller_spec.rb`
- ✅ `spec/models/buyer_portal_access_preferences_spec.rb`
- ✅ `create_test_preferences.rb`
- ✅ `run_phase4d_complete_tests.sh`
- ✅ `PHASE4D_COMPLETE_README.md` (this file)

## Success Metrics ✅

- [x] All 60+ tests passing
- [x] All 3 endpoints functional
- [x] Change history tracking works
- [x] Security validation works  
- [x] Cannot disable portal_enabled
- [x] Boolean validation works
- [x] Authentication required
- [x] Follows Phase 4A/4B/4C patterns
- [x] SQLite compatible
- [x] Test data script works
- [x] curl examples work

## Next Steps

Phase 4D is complete! The buyer portal now has full communication preference management with:
- ✅ View/update preferences
- ✅ Complete change history
- ✅ Security controls
- ✅ Full test coverage

Ready to integrate with frontend or move to next phase!

## Quick Start

```bash
# 1. Run tests
./run_phase4d_complete_tests.sh

# 2. Create test data
ruby create_test_preferences.rb

# 3. Test with curl (use token from step 2)
curl -X GET http://localhost:3001/api/portal/preferences \
  -H 'Authorization: Bearer TOKEN_HERE' \
  -H 'Content-Type: application/json'
```

---

**Phase 4D Status**: ✅ COMPLETE - All functionality implemented and tested!
