# Phase 2 Additional Fix - Account Messages Controller

## Issue Found in Production UI

**Error:** `NameError: uninitialized constant Api::V1::AccountMessagesController::CommunicationLog`

**Location:** AI Insights page when loading account messages

**Root Cause:** The `AccountMessagesController` was still using the old `CommunicationLog` model instead of the new Phase 2 `Communication` model.

---

## What Was Fixed

Updated `app/controllers/api/v1/account_messages_controller.rb` to use Phase 2 models and architecture:

### Key Changes:

1. **Index Action** - Get messages for account
```ruby
# OLD
logs = CommunicationLog.for_account(@account.id).recent

# NEW
communications = Communication.where(communicable: @account)
                              .order(created_at: :desc)
                              .limit(100)
```

2. **Send Email** - Create email communication
```ruby
# OLD
CommunicationLog.create!(
  account: @account,
  comm_type: 'email',
  direction: 'outbound',
  ...
)

# NEW
Communication.create!(
  communicable: @account,
  channel: 'email',
  direction: 'outbound',
  ...
)
```

3. **Send SMS** - Create SMS communication
```ruby
# OLD
CommunicationLog.create!(
  account: @account,
  comm_type: 'sms',
  ...
)

# NEW
Communication.create!(
  communicable: @account,
  channel: 'sms',
  ...
)
```

4. **JSON Serialization** - Updated field mappings
```ruby
# OLD
{
  type: log.comm_type,
  content: log.content,
  accountId: log.account_id
}

# NEW
{
  type: communication.channel,
  content: communication.body,
  accountId: communication.communicable_id
}
```

---

## Phase 2 Model Differences

| Old (CommunicationLog) | New (Communication) | Notes |
|------------------------|---------------------|-------|
| `account:` | `communicable:` | Polymorphic association |
| `comm_type` | `channel` | Field name change |
| `content` | `body` | Field name change |
| `account_id` | `communicable_id` | Polymorphic field |

---

## Testing

The fix should resolve the 500 error when:
1. Loading AI Insights page
2. Viewing account messages
3. Sending emails from the UI
4. Sending SMS from the UI

---

## Files Modified

- `app/controllers/api/v1/account_messages_controller.rb` - Updated to use Phase 2 Communication model

---

## Why This Wasn't Caught Earlier

This controller interfaces with the UI and wasn't part of the Phase 2 RSpec test suite. The Phase 2 tests focused on:
- Models
- Services
- Jobs
- Background processing

But didn't test the API controllers that the frontend uses.

---

## Next Steps

1. Test the AI Insights page in the UI - should load without errors
2. Test sending a message from the account view
3. Verify message history displays correctly

---

## Status

✅ **FIXED** - Controller now uses Phase 2 Communication model
✅ Should work with AI Insights page
✅ Compatible with existing UI expectations

The UI should now load messages successfully!
