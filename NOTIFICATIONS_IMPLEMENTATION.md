# Activity Notifications System - Implementation Summary

## Overview
Implemented a complete notification system for Lead Activities that follows the same settings pattern as the existing communications system (Platform settings with Company override).

## Backend Implementation ✅

### 1. Settings Controllers Updated
- **Platform Settings** (`app/controllers/api/platform/settings_controller.rb`)
  - Added `notifications` settings alongside `communications`
  - Default settings for email, SMS, and popup notifications

- **Company Settings** (`app/controllers/api/company/settings_controller.rb`)
  - Added `notifications_settings` getter/setter
  - Company settings override platform settings

### 2. Company Model Updated
- Added `notifications_settings` and `notifications_settings=` methods
- Stores settings in polymorphic `settings` table (same as communications)

### 3. Notification Service Created
**File:** `app/services/activity_notification_service.rb`

Features:
- Checks settings hierarchy (Company → Platform)
- Sends notifications based on activity type and settings
- Three notification channels: Email, SMS, Popup

**Email Notifications:**
- Uses ActionMailer
- Queued with `deliver_later` for async sending
- Settings: `email.isEnabled`, `email.sendReminders`, `email.sendActivityUpdates`

**SMS Notifications:**
- Uses existing Twilio integration from communications
- Only sends for urgent activities if `sms.sendUrgentOnly` is true
- Settings: `sms.isEnabled`, `sms.sendReminders`, `sms.sendUrgentOnly`

**Popup Notifications:**
- Uses ActionCable for real-time browser notifications
- NO EXTERNAL SERVICE NEEDED - built into Rails!
- Broadcasts to user-specific channel: `user_notifications_#{user_id}`
- Settings: `popup.isEnabled`, `popup.showReminders`, `popup.showActivityUpdates`

### 4. Activity Mailer Created
**File:** `app/mailers/activity_mailer.rb`

Methods:
- `activity_notification(activity, user)` - For new activities
- `reminder_notification(activity)` - For scheduled reminders

Email Templates:
- HTML version: `app/views/activity_mailer/activity_notification.html.erb`
- Text version: `app/views/activity_mailer/activity_notification.text.erb`

### 5. LeadActivity Model Updated
- `after_create :send_creation_notifications` - Sends notifications when activity is created
- Integrated with `ActivityNotificationService`

### 6. ActivityReminderJob Updated
- Uses `ActivityNotificationService` to send reminders
- Marks reminder as sent after delivery

## Settings Structure

### Platform Settings (Default)
```json
{
  "notifications": {
    "email": {
      "isEnabled": true,
      "sendReminders": true,
      "sendActivityUpdates": true,
      "dailyDigest": false
    },
    "sms": {
      "isEnabled": false,
      "sendReminders": true,
      "sendUrgentOnly": true
    },
    "popup": {
      "isEnabled": true,
      "showReminders": true,
      "showActivityUpdates": true,
      "autoClose": true,
      "autoCloseDelay": 5000
    }
  }
}
```

### Company Settings (Override)
Stored in `settings` table with:
- `scope_type`: 'Company'
- `scope_id`: company.id
- `key`: 'notifications'
- `value`: JSON (same structure as above)

## API Endpoints

### Get Settings
```
GET /api/platform/settings
GET /api/company/settings
```

Response includes both `communications` and `notifications`

### Update Settings
```
PATCH /api/platform/settings
PATCH /api/company/settings
```

Body:
```json
{
  "notifications": {
    "email": { "isEnabled": true, ... },
    "sms": { "isEnabled": false, ... },
    "popup": { "isEnabled": true, ... }
  }
}
```

## How Notifications Work

### When Activity is Created:
1. User creates activity in UI
2. `LeadActivity` created in database
3. `after_create :send_creation_notifications` triggers
4. `ActivityNotificationService` checks settings
5. Sends appropriate notifications (email/SMS/popup)

### When Reminder Time Arrives:
1. `ActivityReminderJob` runs at scheduled time
2. Checks `reminder_method` array (email, popup, sms)
3. Sends notifications through configured channels
4. Marks `reminder_sent = true`

## Popup Notifications

### No External Service Required!
Popup notifications use **ActionCable** (built into Rails) for WebSocket connections.

### How it Works:
1. Backend broadcasts to user channel
2. Frontend subscribes to channel
3. Real-time messages appear as toast notifications
4. Auto-closes after configured delay

### Frontend Setup Needed:
1. Create ActionCable consumer
2. Subscribe to `user_notifications_#{userId}` channel
3. Display toast/notification component
4. Handle auto-close based on settings

## Email Configuration

### Development:
Configure in `config/environments/development.rb`:
```ruby
config.action_mailer.delivery_method = :smtp
config.action_mailer.smtp_settings = {
  address: 'smtp.gmail.com',
  port: 587,
  domain: 'example.com',
  user_name: ENV['SMTP_USERNAME'],
  password: ENV['SMTP_PASSWORD'],
  authentication: 'plain',
  enable_starttls_auto: true
}
```

### Production:
Use environment variables from Platform/Company settings

## SMS Configuration

Uses existing Twilio integration from communications system.

Configure in Company settings:
- `communications.sms.provider`: 'twilio'
- `communications.sms.fromNumber`: '+1234567890'
- Add Twilio credentials to environment

## Testing

### Test Email Notification:
```bash
rails runner "
  activity = LeadActivity.first
  ActivityMailer.activity_notification(activity, activity.assigned_to).deliver_now
"
```

### Test Popup Notification:
```bash
rails runner "
  activity = LeadActivity.first
  ActivityNotificationService.new(activity).send_popup_notification
"
```

### Check Settings:
```bash
rails runner "
  company = Company.first
  puts company.notifications_settings.inspect
"
```

## Next Steps: Frontend Implementation

### 1. Calendar View Component (see separate file)
### 2. Popup Notification Component (ActionCable consumer)
### 3. Settings UI for notification preferences
### 4. User notification preferences page

## Files Created/Modified

### Created:
- `app/services/activity_notification_service.rb`
- `app/mailers/activity_mailer.rb`
- `app/views/activity_mailer/activity_notification.html.erb`
- `app/views/activity_mailer/activity_notification.text.erb`

### Modified:
- `app/controllers/api/platform/settings_controller.rb`
- `app/controllers/api/company/settings_controller.rb`
- `app/models/company.rb`
- `app/models/lead_activity.rb`
- `app/jobs/activity_reminder_job.rb`

## Summary

✅ Email notifications - Wired to platform/company settings
✅ SMS notifications - Wired to platform/company settings (uses existing Twilio)
✅ Popup notifications - Uses ActionCable (NO external service needed!)
✅ Settings hierarchy - Company overrides platform
✅ Async delivery - All notifications queued with background jobs
✅ Flexible configuration - Per-notification-type settings

**Ready to implement frontend calendar view and popup notification components!**
