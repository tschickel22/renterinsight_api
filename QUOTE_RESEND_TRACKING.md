# Quote Resend Tracking - Implementation Summary

## Overview
Added comprehensive tracking for quote sending and resending with visual indicators in the UI.

## Database Changes

### New Migration
**File**: `db/migrate/20251018200000_add_resend_tracking_to_quotes.rb`

**New Columns**:
- `resend_count` (integer, default: 0) - Tracks how many times a quote has been resent
- `last_sent_at` (datetime) - Tracks the most recent send time

**Data Backfill**:
- Existing quotes have `last_sent_at` set to their `sent_at` value

## Backend Changes

### Quote Model (`app/models/quote.rb`)

**Updated `send!` method**:
```ruby
def send!
  # Allow sending for draft quotes or resending for sent/viewed quotes
  return false unless %w[draft sent viewed].include?(status)
  
  is_resend = !draft? && sent_at.present?
  
  update!(
    status: 'sent',
    sent_at: is_resend ? sent_at : Time.current,  # Keep original sent_at
    last_sent_at: Time.current,  # Always update last_sent_at
    resend_count: is_resend ? (resend_count + 1) : 0  # Increment on resend
  )
end
```

**Behavior**:
- **First Send**: Sets `sent_at` and `last_sent_at` to current time, `resend_count` = 0
- **Resend**: Keeps original `sent_at`, updates `last_sent_at`, increments `resend_count`

**Updated `as_json` method**:
- Added `last_sent_at` field to API responses
- Added `resend_count` field to API responses

## Frontend Changes

### TypeScript Types (`src/types/index.ts`)

**Updated Quote interface**:
```typescript
export interface Quote {
  // ... existing fields ...
  sent_at?: Date | string
  last_sent_at?: Date | string
  resend_count?: number
  // ... other fields ...
}
```

### UI Updates (`src/components/shared/QuotesSection.tsx`)

#### 1. Timeline Display
Shows detailed send/resend history:
```
✓ First sent Oct 15, 2025 • Resent 3 times, last on Oct 18, 2025
```

**Display Logic**:
- **Never Sent**: No timeline entry
- **Sent Once**: "Sent {date}"
- **Resent**: "First sent {date} • Resent X times, last on {date}"

#### 2. Dropdown Menu
Added "Resend Quote" option that appears for quotes with status 'sent' or 'viewed'

#### 3. Action Buttons
- **Draft quotes**: Shows "Send" button
- **Sent/Viewed quotes**: Shows "Resend" button

#### 4. Toast Messages
Smart messages based on action:
- "Quote sent successfully" vs "Quote resent successfully"
- Different error messages for send vs resend

## How to Apply

### 1. Run the Migration
```bash
cd /home/tschi/src/renterinsight_api
bash add_quote_resend_tracking.sh
```

Or manually:
```bash
cd /home/tschi/src/renterinsight_api
bundle exec rails db:migrate
```

### 2. Restart Rails Server
```bash
# Kill and restart your Rails server
```

### 3. Test the Feature
1. Go to a contact with quotes
2. Send a draft quote - should show "Sent {date}"
3. Resend the quote - should show "First sent {date} • Resent 1 time, last on {date}"
4. Resend again - count should increment

## Visual Examples

### Timeline Entry (No Resends)
```
📅 Created Oct 12, 2025
📤 Sent Oct 15, 2025
```

### Timeline Entry (With Resends)
```
📅 Created Oct 12, 2025
📤 First sent Oct 15, 2025 • Resent 3 times, last on Oct 18, 2025
👁️ Viewed Oct 16, 2025
```

## Database Schema

```sql
ALTER TABLE quotes 
  ADD COLUMN resend_count INTEGER DEFAULT 0 NOT NULL,
  ADD COLUMN last_sent_at TIMESTAMP;

-- Backfill existing data
UPDATE quotes 
SET last_sent_at = sent_at 
WHERE sent_at IS NOT NULL;
```

## API Response Example

```json
{
  "id": "123",
  "quoteNumber": "QUO-2025-ABC123",
  "status": "sent",
  "sent_at": "2025-10-15T10:30:00Z",
  "last_sent_at": "2025-10-18T14:45:00Z",
  "resend_count": 3,
  "viewed_at": "2025-10-16T09:15:00Z",
  "total": 42750.72
}
```

## Files Modified

### Backend
1. `db/migrate/20251018200000_add_resend_tracking_to_quotes.rb` (NEW)
2. `app/models/quote.rb` (UPDATED)

### Frontend
1. `src/types/index.ts` (UPDATED)
2. `src/components/shared/QuotesSection.tsx` (UPDATED)

### Scripts
1. `add_quote_resend_tracking.sh` (NEW)

## Benefits

✅ **Track Send History**: Know exactly when a quote was first sent and how many times it's been resent
✅ **Visual Indicators**: Clear, color-coded timeline shows resend information
✅ **Better Analytics**: Can analyze which quotes need multiple sends
✅ **Audit Trail**: Complete history of all send attempts
✅ **User-Friendly**: Shows information in an easy-to-understand format

## Next Steps

After applying the migration:
1. Monitor the logs for any errors
2. Test sending and resending quotes
3. Verify timeline displays correctly
4. Check that resend count increments properly
