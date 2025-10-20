# Quick Fix for Quote Communication Error

## The Problem
Getting error: "Recipient has opted out of communication" when sending Quote #21 (or other quotes), but the contact/account shows as opted in.

## The Solution (One Command)

```bash
rails runner lib/quick_fix_quote_prefs.rb
```

This will:
1. ✅ Diagnose the issue
2. ✅ Show you what will be fixed
3. ✅ Ask for confirmation
4. ✅ Migrate old Quote-level preferences to Contact/Account level
5. ✅ Verify the fix

## Alternative Commands

### See what's wrong:
```bash
rails runner lib/debug_quote_preferences.rb 21
```

### Migrate preferences (preserves history):
```bash
rake fix:quote_preferences
```

### Just delete old preferences (simpler):
```bash
rake fix:delete_quote_preferences
```

## After Running the Fix

Try sending your quote again - it should work now! 🎉

## More Information

See `COMMUNICATION_PREFERENCE_FIX.md` for detailed explanation of the issue and fix.
