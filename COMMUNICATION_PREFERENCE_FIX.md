# Communication Preference Fix Guide

## Problem Summary

**Error**: "Recipient has opted out of communication" when trying to send quotes, even though the contact/account shows as opted in.

**Root Cause**: The database contains `CommunicationPreference` records with `recipient_type='Quote'` instead of `recipient_type='Contact'` or `recipient_type='Account'`. These were created by old code before the fix was implemented.

**SQL Evidence**:
```sql
SELECT * FROM communication_preferences 
WHERE recipient_type = 'Quote' AND recipient_id = 21
```

## Why This Happens

1. **Old Behavior (WRONG)**: The system was checking/storing preferences on the Quote object itself
2. **New Behavior (CORRECT)**: The system should check/store preferences on the Contact or Account associated with the quote
3. **The Issue**: Old preference records still exist in the database

## The Fix

The `CommunicationService` has been updated with a `determine_recipient_for_preference_check` method that correctly extracts the Contact or Account from a Quote. However, old preference data needs to be cleaned up.

## Step-by-Step Resolution

### Step 1: Diagnose the Issue

Run the debug script to see what preference records exist:

```bash
cd /home/tschi/src/renterinsight_api
rails runner lib/debug_quote_preferences.rb 21
```

Replace `21` with your quote ID. This will show:
- Whether Quote-level preferences exist (THE PROBLEM)
- What Contact/Account preferences exist (THE CORRECT ONES)
- What the system should be checking

### Step 2: Choose Your Fix Method

#### Option A: Migrate Preferences (Recommended - Preserves History)

This migrates Quote-level preferences to the associated Contact/Account:

```bash
rake fix:quote_preferences
```

This task will:
- Find all Quote-level preferences
- Migrate them to the Contact or Account
- Handle conflicts intelligently
- Delete the old Quote-level records

#### Option B: Delete Quote Preferences (Simpler - Loses History)

This simply deletes all Quote-level preferences:

```bash
rake fix:delete_quote_preferences
```

After deletion, the system will default to opted-in for transactional/quote communications.

### Step 3: Verify the Fix

#### Check database:
```bash
rails runner "puts CommunicationPreference.where(recipient_type: 'Quote').count"
```

Should return `0`.

#### Test sending:
```ruby
# In rails console
quote = Quote.find(21)
service = QuoteSendingService.new(quote)
result = service.send(
  delivery_methods: ['email'],
  to_email: quote.primary_email
)

puts result.inspect
```

Should work without errors!

### Step 4: Monitor Going Forward

#### View all Quote preferences:
```bash
rake fix:show_quote_preferences
```

This shows any remaining Quote-level preferences and what they should be migrated to.

## Understanding the Code Fix

### What Changed in `CommunicationService`:

**Before (implied old code)**:
```ruby
# Directly checking preferences on the Quote
can_send_to_recipient?(
  recipient: quote,  # ❌ WRONG
  channel: channel,
  category: category
)
```

**After (current code)**:
```ruby
# Extract the actual recipient first
recipient_for_check = determine_recipient_for_preference_check(communicable)

# Then check preferences on Contact/Account
if recipient_for_check && !can_send_to_recipient?(
  recipient: recipient_for_check,  # ✅ CORRECT
  channel: channel,
  category: category
)
```

### The `determine_recipient_for_preference_check` Method:

```ruby
def determine_recipient_for_preference_check(communicable)
  case communicable.class.name
  when 'Quote'
    # Check contact first, then account
    communicable.contact || communicable.account
  when 'Account', 'Contact'
    # These are already the right recipient
    communicable
  else
    # For other types, just use the communicable
    communicable
  end
end
```

This correctly extracts the Contact or Account from a Quote.

## Prevention

### Database Constraint (Optional)

To prevent Quote-level preferences from being created in the future, you could add a database constraint:

```ruby
# db/migrate/XXXXXX_add_check_constraint_to_communication_preferences.rb
class AddCheckConstraintToCommunicationPreferences < ActiveRecord::Migration[7.0]
  def up
    execute <<-SQL
      ALTER TABLE communication_preferences
      ADD CONSTRAINT check_recipient_type
      CHECK (recipient_type IN ('Account', 'Contact', 'User'));
    SQL
  end

  def down
    execute <<-SQL
      ALTER TABLE communication_preferences
      DROP CONSTRAINT check_recipient_type;
    SQL
  end
end
```

### Model Validation

Add validation to `CommunicationPreference` model:

```ruby
validates :recipient_type, inclusion: { 
  in: %w[Account Contact User],
  message: "must be Account, Contact, or User (not Quote)" 
}
```

## Troubleshooting

### Error Still Occurs After Cleanup

1. Restart your Rails server
2. Clear any caches
3. Run debug script again to verify Quote prefs are gone
4. Check if there's a before_action in controller checking prefs

### Quote Has No Contact or Account

If a quote has no contact or account:
- The preference check will be skipped (no error)
- You need to assign a contact or account to the quote
- Update the quote: `quote.update(contact_id: ...)`

### Need to Opt Someone Out

Do it at the Contact or Account level:

```ruby
# In rails console
contact = Contact.find(123)

# Opt out of marketing emails
CommunicationPreferenceService.opt_out(
  recipient: contact,
  channel: 'email',
  category: 'marketing',
  reason: 'Customer request'
)
```

## Quick Reference

```bash
# See all Quote-level preferences
rake fix:show_quote_preferences

# Migrate them (recommended)
rake fix:quote_preferences

# Or delete them (simpler)
rake fix:delete_quote_preferences

# Verify cleanup
rails runner "puts CommunicationPreference.where(recipient_type: 'Quote').count"

# Debug specific quote
rails runner lib/debug_quote_preferences.rb <quote_id>
```

## Summary

The fix is two-part:
1. **Code Fix**: ✅ Already done in `CommunicationService`
2. **Data Fix**: Run `rake fix:quote_preferences` to clean up old data

After running the data migration, quote sending should work correctly! 🎉
