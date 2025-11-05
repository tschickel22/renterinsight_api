# INVITATION URL FIX - COMPLETE SOLUTION

## Problem
Invitation emails were sending users to `/login` instead of `/invitations/accept?token=...`

The issue was with **old merge variables** in the communication templates:
- Old: `{{login_url}}`, `{{admin_name}}`, `{{admin_email}}`, `{{user_name}}`
- New: `{{invitation_url}}`, `{{invited_by}}`, `{{first_name}}`, `{{recipient_name}}`

## Root Cause
The **database templates** in staging still had the old variable names, even though:
- ✅ Frontend routes were correctly set up (`/invitations/accept`)
- ✅ Backend controller was generating correct URLs
- ✅ Seed file had correct templates

## Files Changed

### Backend Changes
1. **app/models/communication_template.rb**
   - Updated MERGE_VARIABLES to include all new variable names
   - Removed old variables like `admin_name`, `admin_email`
   - Added: `recipient_name`, `first_name`, `invitation_url`, etc.

### Frontend Changes
2. **src/types/invitation.ts**
   - Updated TEMPLATE_VARIABLES array
   - Changed `login_url` → `invitation_url` (with note to use invitation_url)
   - Changed `admin_name` → `invited_by`
   - Changed `admin_email` → removed
   - Changed `user_name` → `first_name` + `recipient_name`
   - Added all new variables: `email`, `phone`, `role`, `invitation_token`, `days_until_expiry`

### Update Scripts
3. **update_invitation_templates.rb**
   - Script to update database templates with correct variables
   - Deletes old templates and creates new ones
   - Uses `{{invitation_url}}` instead of `{{login_url}}`

4. **update_templates_now.sh**
   - Quick command to run the update script

## How to Fix in Staging

### Step 1: Update the Database Templates
```bash
cd /path/to/renterinsight_api
bash update_templates_now.sh
```

Or manually:
```bash
bundle exec rails runner update_invitation_templates.rb
```

### Step 2: Deploy Frontend Changes
The frontend changes have been made to:
- `src/types/invitation.ts` - Updated TEMPLATE_VARIABLES

These changes will update the UI to show the correct variable names when creating new templates.

### Step 3: Test the Fix
1. Go to **Company Settings → Users → Invite Templates** tab
2. Click "Create Template"
3. Verify the "Available Variables" section shows:
   - `invitation_url` (not `login_url`)
   - `invited_by` (not `admin_name`)
   - `first_name` (not `user_name`)
   - No `admin_email`

4. Create a test user invitation
5. Check the email/SMS
6. Verify the link goes to: `https://staging.crm.landlordinsight.com/invitations/accept?token=...`
7. Click the link and verify it loads the invitation acceptance page (not login page)

## Variable Mapping Reference

| Old Variable      | New Variable       | Notes                           |
|-------------------|--------------------|---------------------------------|
| `{{user_name}}`   | `{{first_name}}`   | Use first_name or recipient_name |
| `{{user_name}}`   | `{{recipient_name}}`| Full name                       |
| `{{admin_name}}`  | `{{invited_by}}`   | Name of person sending invite   |
| `{{admin_email}}` | *REMOVED*          | Not needed anymore              |
| `{{login_url}}`   | `{{invitation_url}}`| **CRITICAL - This is the fix!** |

## New Variables Available
- `{{email}}` - Email address of invited user
- `{{phone}}` - Phone number of invited user  
- `{{role}}` - Role code (e.g., 'admin')
- `{{invitation_token}}` - Unique token
- `{{days_until_expiry}}` - Number of days (e.g., '7')
- `{{invitation_expires}}` - Full date/time string
- `{{setup_instructions}}` - Account setup instructions

## Testing Checklist

- [ ] Backend templates updated in database
- [ ] Frontend shows new variables in UI
- [ ] Create test user with email delivery
- [ ] Email contains correct `invitation_url` link
- [ ] Link goes to `/invitations/accept?token=...`
- [ ] Page loads properly (not redirected to login)
- [ ] Can set password and complete registration
- [ ] Create test user with SMS delivery  
- [ ] SMS contains correct invitation link
- [ ] SMS link works on mobile

## Important Notes

1. **Existing Templates**: Any templates created BEFORE this fix will still have the old variables. They need to be manually updated or recreated.

2. **Default Templates**: The script creates new default templates. If users have customized templates, they need to update them manually to use `{{invitation_url}}` instead of `{{login_url}}`.

3. **Frontend UI**: After deploying frontend changes, users will see the updated variable list when creating new templates, making it clear which variables to use.

4. **Backend Routes**: The invitation routes are already correctly configured at `/invitations/accept` - this was never the issue. The issue was the templates using `login_url` instead of `invitation_url`.

## Quick Commands Reference

```bash
# Update templates in staging
cd ~/src/renterinsight_api
bash update_templates_now.sh

# Check existing templates
bundle exec rails console
CommunicationTemplate.where(template_type: 'company_user_invitation').each do |t|
  puts "#{t.name} (#{t.channel}): #{t.body.include?('invitation_url') ? '✅ CORRECT' : '❌ NEEDS UPDATE'}"
end

# Manual template check
rails console
template = CommunicationTemplate.find_by(template_type: 'company_user_invitation', channel: 'email')
puts template.body
# Should contain {{invitation_url}} not {{login_url}}
```

## Success Criteria
✅ Users receive invitation emails with `/invitations/accept?token=...` URLs  
✅ Clicking invitation link loads the invitation acceptance page  
✅ Users can set password and complete registration  
✅ No more redirects to login page from invitation links  
✅ UI shows correct available variables when creating templates
