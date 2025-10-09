# Lead Activities Feature - Setup and Troubleshooting Guide

## Quick Start

### 1. Run the Setup Script
```bash
cd /path/to/renterinsight_api
chmod +x setup_lead_activities.sh
./setup_lead_activities.sh
```

This will:
- Run the database migration
- Verify the table was created
- Test CRUD operations
- Provide diagnostic information

### 2. Restart Your Rails Server
```bash
# Stop the current server (Ctrl+C)
# Then restart:
bundle exec rails server -p 3001
```

### 3. Test in Browser
1. Navigate to any lead detail page
2. Click the "Activities" tab
3. Try creating a task, meeting, call, or reminder

## Manual Setup (if script fails)

### Step 1: Run Migration
```bash
cd /path/to/renterinsight_api
bundle exec rails db:migrate
```

### Step 2: Verify Table Creation
```bash
bundle exec rails dbconsole
.schema lead_activities
.exit
```

You should see the table structure with all columns.

### Step 3: Test Model
```bash
bundle exec rails runner test_lead_activities.rb
```

This runs comprehensive tests on all CRUD operations.

## Troubleshooting

### Issue: 500 Error on Create

**Check Rails logs:**
```bash
tail -f log/development.log
```

Look for lines starting with `[LeadActivitiesController#create]`

**Common causes:**
1. **Migration not run**: Table doesn't exist
   - Solution: Run `bundle exec rails db:migrate`

2. **No users in database**: Model requires a user
   - Solution: Create a user first:
   ```bash
   bundle exec rails console
   User.create!(name: "Admin User", email: "admin@example.com")
   ```

3. **Validation errors**: Check which field is failing
   - The logs will show: `Validation failed: [error messages]`
   - Make sure required fields are filled in the form

### Issue: 404 Error on Route

**Verify routes:**
```bash
bundle exec rails routes | grep lead_activities
```

You should see:
```
POST   /api/crm/leads/:lead_id/lead_activities
GET    /api/crm/leads/:lead_id/lead_activities
GET    /api/crm/leads/:lead_id/lead_activities/:id
PATCH  /api/crm/leads/:lead_id/lead_activities/:id
DELETE /api/crm/leads/:lead_id/lead_activities/:id
POST   /api/crm/leads/:lead_id/lead_activities/:id/complete
POST   /api/crm/leads/:lead_id/lead_activities/:id/cancel
```

### Issue: Form Not Showing

**Check browser console for errors:**
- Open DevTools (F12)
- Look for JavaScript errors
- Common issues:
  - Missing import statements
  - TypeScript errors
  - Component not found

### Issue: Data Not Persisting

**Verify database write:**
```bash
bundle exec rails console
LeadActivity.count  # Should show number of activities
LeadActivity.last   # Should show last created activity
```

**Check activity log creation:**
The model should create an Activity log entry. Verify:
```bash
bundle exec rails console
Activity.where(activity_type: 'lead_activity_task').count
```

## Testing Individual Features

### Test Task Creation
```bash
bundle exec rails runner "
  LeadActivity.create!(
    lead: Lead.first,
    user: User.first,
    activity_type: 'task',
    subject: 'Test Task',
    priority: 'high',
    status: 'pending',
    due_date: 3.days.from_now
  )
"
```

### Test Meeting Creation
```bash
bundle exec rails runner "
  LeadActivity.create!(
    lead: Lead.first,
    user: User.first,
    activity_type: 'meeting',
    subject: 'Test Meeting',
    priority: 'high',
    status: 'pending',
    start_time: 2.days.from_now,
    end_time: 2.days.from_now + 1.hour
  )
"
```

### Test Call Creation
```bash
bundle exec rails runner "
  LeadActivity.create!(
    lead: Lead.first,
    user: User.first,
    activity_type: 'call',
    subject: 'Test Call',
    priority: 'medium',
    status: 'pending',
    phone_number: '+1-555-0123',
    call_direction: 'outbound'
  )
"
```

### Test Reminder Creation
```bash
bundle exec rails runner "
  LeadActivity.create!(
    lead: Lead.first,
    user: User.first,
    activity_type: 'reminder',
    subject: 'Test Reminder',
    priority: 'urgent',
    status: 'pending',
    reminder_time: 1.day.from_now,
    reminder_method: ['email', 'popup']
  )
"
```

## API Testing with cURL

### Create a Task
```bash
curl -X POST http://localhost:3001/api/crm/leads/1/lead_activities \
  -H "Content-Type: application/json" \
  -d '{
    "activityType": "task",
    "subject": "Follow up with client",
    "description": "Discuss next steps",
    "priority": "high",
    "status": "pending",
    "dueDate": "2025-10-15T14:00:00Z"
  }'
```

### Get All Activities for a Lead
```bash
curl http://localhost:3001/api/crm/leads/1/lead_activities
```

### Complete an Activity
```bash
curl -X POST http://localhost:3001/api/crm/leads/1/lead_activities/1/complete
```

### Delete an Activity
```bash
curl -X DELETE http://localhost:3001/api/crm/leads/1/lead_activities/1
```

## Database Schema

The `lead_activities` table includes:

**Core Fields:**
- `activity_type`: task, meeting, call, reminder
- `subject`: Activity title (required)
- `description`: Detailed description
- `status`: pending, in_progress, completed, cancelled
- `priority`: low, medium, high, urgent

**Scheduling:**
- `due_date`: For tasks and calls
- `start_time`, `end_time`: For meetings
- `completed_at`: When completed

**Type-Specific:**
- Tasks: `estimated_hours`, `actual_hours`
- Meetings: `meeting_location`, `meeting_link`, `meeting_attendees`
- Calls: `phone_number`, `call_direction`, `call_outcome`
- Reminders: `reminder_time`, `reminder_method`, `reminder_sent`

**Relations:**
- `lead_id`: Associated lead (required)
- `user_id`: Creator (required)
- `assigned_to_id`: Assigned user (optional)
- `related_activity_id`: Link to related activity (optional)

## Common Validation Errors

1. **"Subject can't be blank"**
   - Fill in the subject field

2. **"Start time is required for meetings"**
   - Meetings need both start and end times

3. **"Phone number is required for calls"**
   - Calls need a phone number and direction

4. **"Reminder time is required for reminders"**
   - Reminders need a time and at least one notification method

5. **"Call direction is required for calls"**
   - Must be either 'inbound' or 'outbound'

## Frontend Debugging

### Check if component is loaded:
Open browser console and type:
```javascript
// Should see the LeadActivities component
console.log(document.querySelector('[data-testid="activities-tab"]'))
```

### Check API calls:
Network tab in DevTools should show:
- GET request to `/api/crm/leads/:id/lead_activities` (on tab load)
- POST request to same URL (on create)
- Responses should be 200 (success) or include error details

### Check form data being sent:
In Network tab, click on the POST request and view:
- Request Payload should show activityType, subject, etc.
- Check if data format matches expected format

## Success Checklist

- [ ] Migration ran successfully
- [ ] `lead_activities` table exists in database
- [ ] At least one User exists in database
- [ ] Rails server is running
- [ ] Can navigate to Activities tab
- [ ] Can see the create buttons (Task, Meeting, Call, Reminder)
- [ ] Forms open when clicking buttons
- [ ] Can fill out and submit forms
- [ ] Activities appear in the list after creation
- [ ] Can edit existing activities
- [ ] Can mark activities as complete
- [ ] Activities persist after page refresh

## Support

If you're still having issues after following this guide:

1. Run the setup script and save the output:
   ```bash
   ./setup_lead_activities.sh > setup_output.txt 2>&1
   ```

2. Check the Rails logs:
   ```bash
   tail -100 log/development.log > rails_log.txt
   ```

3. Check browser console errors (copy/paste from DevTools)

4. Provide all three files for troubleshooting
