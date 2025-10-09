# Testing Activity Notifications

## What I Fixed

### Issue 1: Activity Log Validation Error ✅
**Problem:** The `Activity` model didn't recognize `lead_activity_reminder` as a valid activity type.

**Fix:** Added these types to `Activity` model:
- `lead_activity_task`
- `lead_activity_meeting`
- `lead_activity_call`
- `lead_activity_reminder`

### Issue 2: Reminders Don't Reschedule on Update ✅
**Problem:** When you edit an existing reminder's time, it didn't reschedule the notification.

**Fix:** Added `after_update` callback that:
1. Detects when `reminder_time` changes
2. Resets the `reminder_sent` flag
3. Reschedules the reminder job

## How to Test Popup Notifications

### Step 1: Make Sure Frontend is Connected
You need to add the notification hook to your app. 

**Where to add it:** In your main App layout or CRM component

**File:** `src/App.tsx` or `src/modules/crm-prospecting/CRMProspecting.tsx`

**Add this code:**
```typescript
import { useActivityNotifications } from '@/hooks/useActivityNotifications';
import { useAuth } from '@/hooks/useAuth'; // or wherever your auth is

function YourComponent() {
  const { user } = useAuth();
  
  // This connects to ActionCable and shows toast notifications
  useActivityNotifications({
    userId: user?.id,
    onNotification: (data) => {
      console.log('📢 Received notification:', data);
    }
  });

  return (
    // your JSX
  );
}
```

### Step 2: Test Creating a Reminder

1. **Open browser console** (F12)
2. **Go to CRM > Create a new reminder**
   - Set reminder time to **1 minute from now**
   - Check "Popup" in reminder methods
3. **Watch the console** - you should see:
   - `[ActivityNotifications] Connected to notifications channel`
   - After 1 minute: `📢 Received notification: ...`
4. **Watch the screen** - a toast notification should appear

### Step 3: Test Editing a Reminder

1. **Edit an existing reminder**
2. **Change the reminder time** to 1 minute from now
3. **Save**
4. **Watch for popup** after 1 minute

### Step 4: Verify in Rails Logs

**Watch Rails server output:**
```bash
tail -f log/development.log | grep -E "ActivityNotification|ActionCable|Reminder"
```

**You should see:**
```
[LeadActivity] Scheduled reminder job for activity 123 in 60 seconds
[ActivityReminderJob] Sending reminders for activity 123
[ActivityNotification] Broadcast popup for activity 123 to user 1
```

## Troubleshooting

### No Popup Appears

**Check 1: Is ActionCable Connected?**
Open browser console, look for:
```
[ActivityNotifications] Connected to notifications channel
```

If not connected:
- Check Rails server is running on port 3001
- Check WebSocket URL in hook: `ws://localhost:3001/cable`
- Check CORS settings in `config/environments/development.rb`

**Check 2: Are Notifications Enabled?**
Check settings:
```bash
curl http://localhost:3001/api/company/settings | jq '.notifications.popup'
```

Should show:
```json
{
  "isEnabled": true,
  "showReminders": true,
  "showActivityUpdates": true
}
```

**Check 3: Is Reminder Being Sent?**
Check Rails logs:
```bash
tail -f log/development.log | grep "ActivityReminderJob"
```

Should see job executing at the scheduled time.

### Validation Error Still Appears

If you still see "Activity type is not included in the list":
```bash
cd /home/tschi/src/renterinsight_api
bundle exec rails console

# Check what types are valid
Activity::VALID_TYPES

# Should include: "lead_activity_reminder"
```

If not, restart Rails server:
```bash
bundle exec rails s -p 3001
```

## Quick Test Script

Want to test immediately without waiting? Run this in Rails console:

```ruby
# In Rails console (rails c)
activity = LeadActivity.find(YOUR_ACTIVITY_ID)
ActivityNotificationService.new(activity).send_popup_notification
```

Then check browser - you should see a toast notification immediately!

## What Happens When Reminder Fires

1. **ActivityReminderJob** runs at scheduled time
2. **ActivityNotificationService** checks settings
3. If popup enabled → **Broadcasts via ActionCable**
4. **Frontend hook** receives broadcast
5. **Toast notification** appears with:
   - Activity icon (📋 task, 📅 meeting, 📞 call, ⏰ reminder)
   - Subject
   - Description
   - "View Lead" button (if leadId present)
   - Auto-closes after `autoCloseDelay` ms (default 5000)

## Expected Behavior

✅ Create reminder → Notification scheduled  
✅ Edit reminder time → Notification rescheduled  
✅ Reminder fires → Popup appears (if enabled)  
✅ Multiple methods → All selected methods fire (email, SMS, popup)  
✅ Settings disabled → No notification sent

---

**Everything should work now! The validation error is fixed and reminders will reschedule when you edit them.** 🎉
