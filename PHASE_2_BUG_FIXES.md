# Phase 2 Bug Fixes Summary

## Issues Found and Fixed

### 1. CommunicationAnalytics.scheduled_stats - Incorrect 24h Count

**Problem:**
- Test expected 2 communications scheduled within the next 24 hours
- Got 3 because the query was counting all scheduled communications from now until 24 hours from now, including the current time

**Root Cause:**
```ruby
# OLD (incorrect)
.where('scheduled_for <= ?', 24.hours.from_now)
# This includes past scheduled times and current time
```

**Fix:**
```ruby
# NEW (correct)
.where('scheduled_for > ? AND scheduled_for <= ?', Time.current, 24.hours.from_now)
# This only includes future times within the next 24 hours
```

**File Modified:** `app/services/communication_analytics.rb`

---

### 2. ProcessWebhookJob - Double Status Updates

**Problem:**
- Tests expected `mark_as_delivered!` to be called once
- It was being called twice because:
  1. Job called `communication.mark_as_delivered!` directly
  2. Job then called `communication.track_event('delivered', ...)`
  3. The `CommunicationEvent.after_create` callback calls `mark_as_delivered!` again

**Root Cause:**
Redundant status updates - the webhook job was manually updating status AND creating an event that triggers a callback to update status again.

**Fix Strategy:**
Remove direct status update calls from webhook job. Let the `CommunicationEvent` callback handle all status updates. This ensures:
- Single source of truth for status updates
- Proper event tracking
- No duplicate database writes
- Consistent behavior across all webhooks

**Changes Made:**

#### Twilio Webhook Processing:
```ruby
# OLD
when 'sent', 'delivered'
  communication.mark_as_delivered!
  communication.track_event('delivered', provider_data: data)
when 'failed', 'undelivered'
  communication.mark_as_failed!(data['ErrorMessage'] || 'Delivery failed')
  communication.track_event('failed', provider_data: data)

# NEW
when 'sent', 'delivered'
  communication.track_event('delivered', provider_data: data)
when 'failed', 'undelivered'
  communication.track_event('failed', provider_data: data.merge('error' => data['ErrorMessage'] || 'Delivery failed'))
```

#### SES Webhook Processing:
```ruby
# OLD
when 'Bounce'
  communication.mark_as_bounced!
  communication.track_event('bounced', provider_data: message)
when 'Delivery'
  communication.mark_as_delivered!
  communication.track_event('delivered', provider_data: message)

# NEW
when 'Bounce'
  communication.track_event('bounced', provider_data: message)
when 'Delivery'
  communication.track_event('delivered', provider_data: message)
```

#### SMTP Webhook Processing:
```ruby
# OLD
when 'delivered'
  communication.mark_as_delivered!
  communication.track_event('delivered', provider_data: data)
when 'bounce', 'dropped'
  communication.mark_as_bounced!
  communication.track_event('bounced', provider_data: data)

# NEW
when 'delivered'
  communication.track_event('delivered', provider_data: data)
when 'bounce', 'dropped'
  communication.track_event('bounced', provider_data: data)
```

**File Modified:** `app/jobs/process_webhook_job.rb`

---

### 3. ProcessWebhookJob Tests - Updated Expectations

**Problem:**
Tests were expecting `mark_as_delivered!` to be called, but we changed the implementation to only call `track_event`.

**Fix:**
Updated all test expectations to verify `track_event` is called with correct parameters instead of verifying direct status update methods.

**Test Updates:**

1. **Twilio delivery webhook:**
```ruby
# OLD
expect(communication).to receive(:mark_as_delivered!)

# NEW
expect(communication).to receive(:track_event).with('delivered', provider_data: webhook_data)
```

2. **Twilio failure webhook:**
```ruby
# OLD
expect(communication).to receive(:mark_as_failed!).with('Invalid number')

# NEW
expect(communication).to receive(:track_event).with('failed', provider_data: webhook_data.merge('error' => 'Invalid number'))
```

3. **SES delivery notification:**
```ruby
# OLD
expect(communication).to receive(:mark_as_delivered!)

# NEW
message_hash = JSON.parse(webhook_data['Message'])
expect(communication).to receive(:track_event).with('delivered', provider_data: message_hash)
```

4. **SMTP delivery event:**
```ruby
# OLD
expect(communication).to receive(:mark_as_delivered!)

# NEW
expect(communication).to receive(:track_event).with('delivered', provider_data: webhook_data)
```

**File Modified:** `spec/jobs/process_webhook_job_spec.rb`

---

## How the Event Callback System Works

The `CommunicationEvent` model has an `after_create` callback that automatically updates the parent `Communication` status based on the event type:

```ruby
# From app/models/communication_event.rb
def update_communication_status
  case event_type
  when 'sent'
    communication.mark_as_sent! unless communication.sent?
  when 'delivered'
    communication.mark_as_delivered! unless communication.delivered?
  when 'bounced'
    communication.mark_as_bounced! unless communication.status == 'bounced'
  when 'failed'
    error = details&.dig('error') || 'Unknown error'
    communication.mark_as_failed!(error) unless communication.failed?
  end
end
```

This callback:
- Ensures consistency between events and status
- Prevents duplicate updates with guard clauses (`unless` checks)
- Extracts error messages from event details for failed events
- Centralizes status update logic

---

## Benefits of These Fixes

1. **No Duplicate Database Writes:** Each status change happens exactly once
2. **Single Source of Truth:** Event creation triggers status updates
3. **Better Error Handling:** Error messages properly extracted from event details
4. **Idempotency:** Guard clauses prevent unnecessary updates
5. **Testability:** Tests verify the public API (`track_event`) rather than implementation details
6. **Maintainability:** Webhook processors are simplified - just create events, don't manage status

---

## Test Results Expected

After these fixes, all 84 tests should pass:

```
84 examples, 0 failures
```

Previously failing tests that should now pass:
1. ✅ `CommunicationAnalytics.scheduled_stats returns scheduled communication statistics`
2. ✅ `ProcessWebhookJob#perform with Twilio webhook processes Twilio delivery webhook`
3. ✅ `ProcessWebhookJob#perform with Twilio webhook processes Twilio failure webhook`
4. ✅ `ProcessWebhookJob#perform with AWS SES webhook processes SES delivery notification`
5. ✅ `ProcessWebhookJob#perform with SMTP webhook processes SMTP delivery event`

---

## Running the Tests

Execute the test script:

```bash
chmod +x test_phase2_fixes.sh
./test_phase2_fixes.sh
```

Or run directly:

```bash
bundle exec rspec --format progress \
  spec/models/communication_template_spec.rb \
  spec/services/template_rendering_service_spec.rb \
  spec/services/attachment_service_spec.rb \
  spec/services/communication_analytics_spec.rb \
  spec/jobs/
```

---

## Files Modified

1. `app/services/communication_analytics.rb` - Fixed scheduled_stats query
2. `app/jobs/process_webhook_job.rb` - Removed duplicate status updates
3. `spec/jobs/process_webhook_job_spec.rb` - Updated test expectations
4. `test_phase2_fixes.sh` - Created test runner script (NEW)

---

## Architecture Notes

This fix reveals an important architectural pattern in the codebase:

**Event-Driven Status Updates:**
- External webhooks create `CommunicationEvent` records
- Event creation automatically triggers status updates via callbacks
- This ensures events and statuses stay synchronized
- Webhook processors don't need to know about status management

This pattern makes the system:
- More resilient (events are the source of truth)
- Easier to audit (complete event history)
- Simpler to maintain (centralized update logic)
- More extensible (new event types just need callback cases)
