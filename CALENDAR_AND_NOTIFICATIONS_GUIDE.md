# Activity Notifications & Calendar - Complete Implementation Guide

## 🎉 What's Been Built

### ✅ Backend (Complete)
1. **Email Notifications** - ActionMailer with HTML/text templates
2. **SMS Notifications** - Twilio integration through existing communications settings
3. **Popup Notifications** - ActionCable (WebSockets) for real-time browser notifications
4. **Settings System** - Platform → Company override hierarchy
5. **Notification Service** - Centralized service handling all notification types

### ✅ Frontend (Complete)
1. **Activity Calendar Component** - Full-featured calendar view with month navigation
2. **Popup Notification Hook** - ActionCable consumer with toast notifications
3. **Settings Integration** - Ready to connect to backend settings API

---

## 📦 Installation Steps

### Step 1: Install ActionCable Gem (Already Included in Rails)
ActionCable is built into Rails, so no additional gems needed!

### Step 2: Install Frontend Dependencies

```bash
cd /path/to/frontend
npm install @rails/actioncable date-fns
```

### Step 3: Configure ActionCable in Rails

**File:** `config/cable.yml`
```yaml
development:
  adapter: async

test:
  adapter: test

production:
  adapter: redis
  url: <%= ENV.fetch("REDIS_URL") { "redis://localhost:6379/1" } %>
  channel_prefix: renterinsight_api_production
```

**File:** `config/environments/development.rb`
Add this line:
```ruby
# Mount ActionCable
config.action_cable.mount_path = '/cable'
config.action_cable.allowed_request_origins = [
  'http://localhost:3000',
  'http://127.0.0.1:3000',
  /http:\/\/localhost:*/
]
```

**File:** `config/routes.rb`
Add this line:
```ruby
mount ActionCable.server => '/cable'
```

### Step 4: Restart Rails Server
```bash
bundle exec rails s -p 3001
```

---

## 🚀 Using the Components

### 1. Activity Calendar

**Import and use:**
```typescript
import { ActivityCalendar } from '@/components/common/ActivityCalendar';
import { useLeadActivities } from '@/modules/crm-prospecting/hooks/useLeadActivities';

function MyComponent({ leadId }: { leadId: number }) {
  const { activities } = useLeadActivities(leadId);

  const handleEventClick = (event) => {
    // Navigate to activity details or open edit modal
    console.log('Clicked event:', event);
  };

  const handleDateClick = (date, events) => {
    // Show events for this date in a modal/sidebar
    console.log('Date clicked:', date, 'Events:', events);
  };

  return (
    <ActivityCalendar
      activities={activities}
      onEventClick={handleEventClick}
      onDateClick={handleDateClick}
    />
  );
}
```

**Features:**
- ✅ Month navigation (prev/next/today)
- ✅ Color-coded by activity type (task, meeting, call, reminder)
- ✅ Priority indicators (left border color)
- ✅ Event count badges
- ✅ Clickable events and dates
- ✅ Shows today with blue highlight
- ✅ Responsive grid layout

### 2. Popup Notifications

**Add to your App.tsx or Layout:**
```typescript
import { useActivityNotifications } from '@/hooks/useActivityNotifications';
import { useAuth } from '@/hooks/useAuth'; // Or your auth hook

function AppLayout({ children }) {
  const { user } = useAuth();
  
  // Connect to notifications
  useActivityNotifications({
    userId: user?.id,
    onNotification: (data) => {
      console.log('Received notification:', data);
      // Optional: Play sound, show desktop notification, etc.
    },
  });

  return <div>{children}</div>;
}
```

**Features:**
- ✅ Real-time WebSocket connection
- ✅ Automatic reconnection
- ✅ Toast notifications with activity details
- ✅ Click to navigate to lead
- ✅ Auto-close based on settings
- ✅ Priority-based styling

---

## 🔧 Configuration

### Email Settings

**Configure in `config/environments/development.rb`:**
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

# Set the host for URL generation in emails
config.action_mailer.default_url_options = { host: 'localhost', port: 3000 }
```

### SMS Settings

SMS uses your existing Twilio configuration from communications settings.

**Update Company Settings API:**
```bash
curl -X PATCH http://localhost:3001/api/company/settings \
  -H "Content-Type: application/json" \
  -d '{
    "communications": {
      "sms": {
        "provider": "twilio",
        "fromNumber": "+1234567890",
        "isEnabled": true,
        "accountSid": "YOUR_TWILIO_SID",
        "authToken": "YOUR_TWILIO_TOKEN"
      }
    }
  }'
```

### Notification Preferences

**Get Current Settings:**
```bash
curl http://localhost:3001/api/company/settings
```

**Update Notification Settings:**
```bash
curl -X PATCH http://localhost:3001/api/company/settings \
  -H "Content-Type: application/json" \
  -d '{
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
  }'
```

---

## 📊 Testing

### Test Email Notification
```bash
cd /path/to/renterinsight_api
bundle exec rails runner "
  activity = LeadActivity.first
  ActivityMailer.activity_notification(activity, activity.assigned_to).deliver_now
"
```

### Test Popup Notification
```bash
bundle exec rails runner "
  activity = LeadActivity.first
  ActivityNotificationService.new(activity).send_popup_notification
"
```

### Test in Browser
1. Open browser console
2. Create an activity in the UI
3. You should see:
   - ActionCable connection message
   - Toast notification appears
   - Email sent (check logs)

---

## 🎨 Customization

### Calendar Styling

The calendar uses Tailwind classes. You can customize colors in the component:

```typescript
const ACTIVITY_COLORS = {
  task: 'bg-blue-500',      // Change to your brand color
  meeting: 'bg-purple-500',
  call: 'bg-green-500',
  reminder: 'bg-amber-500'
};

const PRIORITY_BORDERS = {
  low: 'border-l-gray-400',
  medium: 'border-l-blue-500',
  high: 'border-l-orange-500',
  urgent: 'border-l-red-500'
};
```

### Toast Notification Styling

The toast uses your existing `@/components/ui/toast` component from shadcn/ui.

### Email Template Customization

Edit the templates:
- **HTML**: `app/views/activity_mailer/activity_notification.html.erb`
- **Text**: `app/views/activity_mailer/activity_notification.text.erb`

---

## 🔍 Troubleshooting

### ActionCable Not Connecting

**Check Rails logs:**
```bash
tail -f log/development.log | grep -i "action\|cable"
```

**Check browser console:**
```javascript
// Should see: [ActivityNotifications] Connected to notifications channel
```

**Common Issues:**
1. **CORS error** - Add your frontend URL to `allowed_request_origins` in `config/environments/development.rb`
2. **WebSocket upgrade failed** - Make sure you're using `/cable` endpoint
3. **User ID missing** - Pass `userId` to `useActivityNotifications` hook

### Emails Not Sending

**Check logs:**
```bash
tail -f log/development.log | grep -i "mail"
```

**Test SMTP:**
```bash
bundle exec rails console
ActivityMailer.activity_notification(LeadActivity.first, User.first).deliver_now
```

**Common Issues:**
1. **SMTP credentials wrong** - Check ENV variables
2. **Port blocked** - Try port 587 or 465
3. **Authentication failed** - Enable "Less secure app access" for Gmail

### SMS Not Sending

**Check Twilio credentials:**
```bash
bundle exec rails console
company = Company.first
puts company.communications_settings.inspect
```

**Common Issues:**
1. **Twilio credentials not set** - Update company settings
2. **Phone number not verified** - Verify in Twilio dashboard (for trial accounts)
3. **User has no phone** - Add phone to User model

---

## 📁 File Structure

```
Backend (Rails):
├── app/
│   ├── channels/
│   │   ├── application_cable/
│   │   │   ├── channel.rb
│   │   │   └── connection.rb
│   │   └── user_notifications_channel.rb
│   ├── services/
│   │   └── activity_notification_service.rb
│   ├── mailers/
│   │   └── activity_mailer.rb
│   ├── views/
│   │   └── activity_mailer/
│   │       ├── activity_notification.html.erb
│   │       └── activity_notification.text.erb
│   └── models/
│       ├── lead_activity.rb (updated)
│       └── company.rb (updated)

Frontend (React):
├── src/
│   ├── components/
│   │   └── common/
│   │       └── ActivityCalendar.tsx
│   └── hooks/
│       └── useActivityNotifications.ts
```

---

## ✅ Checklist

### Backend Setup
- [ ] Migration run (`rails db:migrate`)
- [ ] ActionCable mounted in routes
- [ ] CORS configured for ActionCable
- [ ] Email SMTP configured
- [ ] Twilio credentials set (if using SMS)

### Frontend Setup
- [ ] `@rails/actioncable` installed
- [ ] `date-fns` installed
- [ ] Calendar component imported
- [ ] Notification hook added to app layout
- [ ] Toast component working

### Testing
- [ ] Create activity triggers email
- [ ] Create activity shows toast notification
- [ ] Calendar displays activities
- [ ] Clicking event opens details
- [ ] Settings can be updated via API

---

## 🚀 Next Steps

### UI Enhancements
1. Create Settings page for notification preferences
2. Add notification history/center
3. Add sound effects for notifications
4. Desktop notifications (browser API)
5. Activity detail modal from calendar

### Backend Enhancements
1. Daily digest email job
2. Notification delivery tracking
3. User preference per notification type
4. Notification templates system
5. Notification analytics

---

## 📞 Support

If you encounter issues:
1. Check Rails logs: `tail -f log/development.log`
2. Check browser console for WebSocket errors
3. Verify settings in database: `Setting.where(key: 'notifications')`
4. Test individual components (email, SMS, popup) separately

**All systems are ready to go! Just install dependencies and restart your servers.** 🎉
